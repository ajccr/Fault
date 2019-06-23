import Foundation
import Defile

class PerVectorSimulation: Simulation {
    struct Test: Encodable {
        var value: UInt
        var bits: Int
        init(value: UInt, bits: Int) {
            self.value = value
            self.bits = bits
        }
    }
    typealias TestVector = [Test]
    struct Coverage: Encodable {
        var sa0: [String]
        var sa1: [String]
        init(sa0: [String], sa1: [String]) {
            self.sa0 = sa0
            self.sa1 = sa1
        }
    }
    
    static func pseudoRandomVerilogGeneration(
        using testVector: TestVector,
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String, 
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        stuckAt: Int,
        cleanUp: Bool
    ) throws -> [String] {
        var portWires = ""
        var portHooks = ""
        var portHooksGM = ""

        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name).gm ;\n"
            portHooks += ".\(name) ( \(name) ) , "
            portHooksGM += ".\(name) ( \(name).gm ) , "
        }

        let folderName = "thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()

        var inputAssignment = ""
        var fmtString = ""
        var inputList = ""

        for (i, input) in inputs.enumerated() {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"

            inputAssignment += "        \(name) = \(testVector[i].value) ;\n"
            inputAssignment += "        \(name).gm = \(name) ;\n"

            fmtString += "%d "
            inputList += "\(name) , "
        }

        fmtString = String(fmtString.dropLast(1))
        inputList = String(inputList.dropLast(2))

        var outputComparison = ""
        for output in outputs {
            let name = (output.name.hasPrefix("\\")) ? output.name : "\\\(output.name)"
            outputComparison += " ( \(name) != \(name).gm ) || "
        }
        outputComparison = String(outputComparison.dropLast(3))

        var faultForces = ""
        for fault in faultPoints {
            faultForces += "        force uut.\(fault) = \(stuckAt) ; \n"   
            faultForces += "        if (difference) $display(\"\(fault)\") ; \n"
            faultForces += "        #1 ; \n"
            faultForces += "        release uut.\(fault) ;\n"
        }

        let bench = """
        \(String.boilerplate)

        `include "\(cells)"
        `include "\(file)"

        module FaultTestbench;

        \(portWires)

            \(module) uut(
                \(portHooks.dropLast(2))
            );
            \(module) gm(
                \(portHooksGM.dropLast(2))
            );

            wire difference ;
            assign difference = (\(outputComparison));

            integer counter;

            initial begin
        \(inputAssignment)
        \(faultForces)
                $finish;
            end

        endmodule
        """;

        let tbName = "\(folderName)/tb.sv"
        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(folderName)/a.out"

        let iverilogResult = "iverilog -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
        if iverilogResult != EX_OK {
            exit(Int32(iverilogResult))
        }

        let vvpTask = Process()
        vvpTask.launchPath = "/usr/bin/env"
        vvpTask.arguments = ["sh", "-c", "vvp \(aoutName)"]
        
        let pipe = Pipe()
        vvpTask.standardOutput = pipe

        vvpTask.launch()
        vvpTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let vvpResult = String(String(data: data, encoding: .utf8)!.dropLast(1))

        if vvpTask.terminationStatus != EX_OK {
            exit(vvpTask.terminationStatus)
        }

        if cleanUp {
            let _ = "rm -rf \(folderName)".sh()
        }

        return vvpResult.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func simulate(
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        tvAttempts: Int,
        sampleRun: Bool
    ) throws -> (json: String, coverage: Float) {

        var futureList: [Future<Coverage>] = []
        
        var testVectors: [TestVector] = []
        for _ in 0..<tvAttempts {
            var testVector: TestVector = []
            for input in inputs {
                let max: UInt = (1 << UInt(input.width)) - 1
                testVector.append(Test(value: UInt.random(in: 0...max), bits: input.width))
            }
            testVectors.append(testVector)
        }

        for vector in testVectors {
            let future = Future<Coverage> {
                do {
                    let sa0 = try PerVectorSimulation.pseudoRandomVerilogGeneration(using: vector, for: faultPoints, in: file, module: module, with: cells, ports: ports, inputs: inputs, outputs: outputs, stuckAt: 0, cleanUp: !sampleRun)

                    let sa1 = try PerVectorSimulation.pseudoRandomVerilogGeneration(using: vector, for: faultPoints, in: file, module: module, with: cells, ports: ports, inputs: inputs, outputs: outputs, stuckAt: 1, cleanUp: !sampleRun)

                    return Coverage(sa0: sa0, sa1: sa1)
                } catch {
                    print("IO Error @ vector \(vector)")
                    return Coverage(sa0: [], sa1: [])

                }
            }
            futureList.append(future)
            if sampleRun {
                break
            }
        }

        var sa0Covered: Set<String> = []
        sa0Covered.reserveCapacity(faultPoints.count)
        var sa1Covered: Set<String> = []
        sa1Covered.reserveCapacity(faultPoints.count)


        struct TVCPair: Encodable {
            var vector: TestVector
            var coverage: Coverage

            init(vector: TestVector, coverage: Coverage) {
                self.vector = vector
                self.coverage = coverage
            }
        }
        var coverageList: [TVCPair] = []

        for (i, future) in futureList.enumerated() {
            let coverLists = future.value
            for cover in coverLists.sa0 {
                sa0Covered.insert(cover)
            }
            for cover in coverLists.sa1 {
                sa1Covered.insert(cover)
            }
            coverageList.append(TVCPair(vector: testVectors[i], coverage: coverLists))
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(coverageList)
        guard let string = String(data: data, encoding: .utf8)
        else {
            throw "Could not create utf8 string."
        }

        return (json: string, coverage: Float(sa0Covered.count + sa1Covered.count) / Float(2 * faultPoints.count))
    }
}