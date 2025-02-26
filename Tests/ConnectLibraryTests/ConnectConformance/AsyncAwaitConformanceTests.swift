// Copyright 2022-2023 The Connect Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Connect
import Foundation
import SwiftProtobuf
import XCTest

private let kTimeout = TimeInterval(10.0)

private typealias TestServiceClient = Connectrpc_Conformance_V1_TestServiceClient
private typealias UnimplementedServiceClient = Connectrpc_Conformance_V1_UnimplementedServiceClient

/// This test suite runs against multiple protocols and serialization formats.
/// Tests are based on https://github.com/connectrpc/conformance
///
/// Tests are written using async/await APIs.
@available(iOS 13, *)
final class AsyncAwaitConformanceTests: XCTestCase {
    private func executeTestWithClients(
        timeout: TimeInterval = 60,
        runTestsWithClient: (TestServiceClient) async throws -> Void
    ) async rethrows {
        let configurations = ConformanceConfiguration.all(timeout: timeout)
        for configuration in configurations {
            try await runTestsWithClient(TestServiceClient(client: configuration.protocolClient))
        }
    }

    private func executeTestWithConnectOnlyClients(
        runTestsWithClient: (TestServiceClient) async -> Void
    ) async {
        let configurations = ConformanceConfiguration.all(timeout: 60)
        for configuration in configurations {
            if case .connect = configuration.networkProtocol {
                await runTestsWithClient(TestServiceClient(client: configuration.protocolClient))
            }
        }
    }

    private func executeTestWithUnimplementedClients(
        runTestsWithClient: (UnimplementedServiceClient) async throws -> Void
    ) async rethrows {
        let configurations = ConformanceConfiguration.all(timeout: 60)
        for configuration in configurations {
            try await runTestsWithClient(
                UnimplementedServiceClient(client: configuration.protocolClient)
            )
        }
    }

    // MARK: - Conformance cases

    func testEmptyUnary() async {
        await self.executeTestWithClients { client in
            let response = await client.emptyCall(request: SwiftProtobuf.Google_Protobuf_Empty())
            XCTAssertEqual(response.message, SwiftProtobuf.Google_Protobuf_Empty())
        }
    }

    func testLargeUnary() async {
        await self.executeTestWithClients { client in
            let size = 314_159
            let message = Connectrpc_Conformance_V1_SimpleRequest.with { proto in
                proto.responseSize = Int32(size)
                proto.payload = .with { $0.body = Data(repeating: 0, count: size) }
            }
            let response = await client.unaryCall(request: message)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.message?.payload.body.count, size)
        }
    }

    func testCacheableUnary() async {
        await self.executeTestWithConnectOnlyClients { client in
            let size = 123
            let message = Connectrpc_Conformance_V1_SimpleRequest.with { proto in
                proto.responseSize = Int32(size)
                proto.payload = .with { $0.body = Data(repeating: 0, count: size) }
            }
            let response = await client.cacheableUnaryCall(request: message)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.headers["get-request"], ["true"])
            XCTAssertEqual(response.message?.payload.body.count, size)
        }
    }

    func testClientStreaming() async throws {
        func createPayload(bytes: Int) -> Connectrpc_Conformance_V1_StreamingInputCallRequest {
            return .with { request in
                request.payload = .with { $0.body = Data(repeating: 1, count: bytes) }
            }
        }

        try await self.executeTestWithClients { client in
            let stream = client.streamingInputCall()
            try stream
                .send(createPayload(bytes: 250 * 1_024))
                .send(createPayload(bytes: 8))
                .send(createPayload(bytes: 1_024))
                .send(createPayload(bytes: 32 * 1_024))
                .close()

            let results = await stream
                .results()
                .compactMap(\.messageValue?.aggregatedPayloadSize)
                .reduce(into: []) { $0.append($1) }
            XCTAssertEqual(results, [289_800])
        }
    }

    func testServerStreaming() async throws {
        try await self.executeTestWithClients { client in
            let sizes = [31_415, 9, 2_653, 58_979]
            let stream = client.streamingOutputCall()
            try stream.send(Connectrpc_Conformance_V1_StreamingOutputCallRequest.with { proto in
                proto.responseParameters = sizes.enumerated().map { index, size in
                    return .with { parameters in
                        parameters.size = Int32(size)
                        parameters.intervalUs = Int32(index * 10)
                    }
                }
            })

            let expectation = self.expectation(description: "Stream completes")
            var responseCount = 0
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message(let output):
                    XCTAssertEqual(output.payload.body.count, sizes[responseCount])
                    responseCount += 1

                case .complete(let code, let error, _):
                    XCTAssertEqual(code, .ok)
                    XCTAssertNil(error)
                    expectation.fulfill()
                }
            }

            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
            XCTAssertEqual(responseCount, 4)
        }
    }

    func testPingPong() async throws {
        func createPayload(
            requestSize: Int,
            responseSize: Int32
        ) -> Connectrpc_Conformance_V1_StreamingOutputCallRequest {
            return .with { request in
                request.payload = .with { $0.body = Data(repeating: 0, count: requestSize) }
                request.responseParameters = [.with { $0.size = responseSize }]
            }
        }

        try await self.executeTestWithClients { client in
            var requests = [
                createPayload(requestSize: 250 * 1_024, responseSize: 500 * 1_024),
                createPayload(requestSize: 8, responseSize: 16),
                createPayload(requestSize: 1_024, responseSize: 2 * 1_024),
                createPayload(requestSize: 32 * 1_024, responseSize: 64 * 1_024),
            ]
            var responseSizes = [Int]()

            let stream = client.fullDuplexCall()
            _ = try stream.send(requests.removeFirst())
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message(let output):
                    responseSizes.append(output.payload.body.count)
                    if requests.isEmpty {
                        stream.close()
                    } else {
                        _ = try stream.send(requests.removeFirst())
                    }

                case .complete(let code, let error, _):
                    XCTAssertEqual(code, .ok)
                    XCTAssertNil(error)
                }
            }

            XCTAssertEqual(responseSizes, [
                500 * 1_024,
                16,
                2 * 1_024,
                64 * 1_024,
            ])
        }
    }

    func testEmptyStream() async throws {
        try await self.executeTestWithClients { client in
            let closeExpectation = self.expectation(description: "Stream completes")
            let stream = client.streamingOutputCall()
            try stream.send(Connectrpc_Conformance_V1_StreamingOutputCallRequest.with { proto in
                proto.responseParameters = []
            })
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message:
                    XCTFail("Unexpectedly received message")

                case .complete(let code, let error, _):
                    XCTAssertEqual(code, .ok)
                    XCTAssertNil(error)
                    closeExpectation.fulfill()
                }
            }

            XCTAssertEqual(XCTWaiter().wait(for: [closeExpectation], timeout: kTimeout), .completed)
        }
    }

    func testCustomMetadata() async {
        await self.executeTestWithClients { client in
            let size = 314_159
            let leadingKey = "x-grpc-test-echo-initial"
            let leadingValue = "test_initial_metadata_value"
            let trailingKey = "x-grpc-test-echo-trailing-bin"
            let trailingValue = Data([0xab, 0xab, 0xab])
            let headers: Headers = [
                leadingKey: [leadingValue],
                trailingKey: [trailingValue.base64EncodedString()],
            ]
            let message = Connectrpc_Conformance_V1_SimpleRequest.with { proto in
                proto.responseSize = Int32(size)
                proto.payload = .with { $0.body = Data(repeating: 0, count: size) }
            }

            let response = await client.unaryCall(request: message, headers: headers)
            XCTAssertEqual(response.code, .ok)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.headers[leadingKey], [leadingValue])
            XCTAssertEqual(
                response.trailers[trailingKey], [trailingValue.base64EncodedString()]
            )
            XCTAssertEqual(response.message?.payload.body.count, size)
        }
    }

    func testCustomMetadataServerStreaming() async throws {
        let size = 314_159
        let leadingKey = "x-grpc-test-echo-initial"
        let leadingValue = "test_initial_metadata_value"
        let trailingKey = "x-grpc-test-echo-trailing-bin"
        let trailingValue = Data([0xab, 0xab, 0xab])
        let headers: Headers = [
            leadingKey: [leadingValue],
            trailingKey: [trailingValue.base64EncodedString()],
        ]

        try await self.executeTestWithClients { client in
            let headersExpectation = self.expectation(description: "Receives headers")
            let messageExpectation = self.expectation(description: "Receives message")
            let trailersExpectation = self.expectation(description: "Receives trailers")
            let stream = client.streamingOutputCall(headers: headers)
            try stream.send(Connectrpc_Conformance_V1_StreamingOutputCallRequest.with { proto in
                proto.responseParameters = [.with { $0.size = Int32(size) }]
            })
            for await result in stream.results() {
                switch result {
                case .headers(let headers):
                    XCTAssertEqual(headers[leadingKey], [leadingValue])
                    headersExpectation.fulfill()

                case .message(let message):
                    XCTAssertEqual(message.payload.body.count, size)
                    messageExpectation.fulfill()

                case .complete(let code, let error, let trailers):
                    XCTAssertEqual(code, .ok)
                    XCTAssertEqual(trailers?[trailingKey], [trailingValue.base64EncodedString()])
                    XCTAssertNil(error)
                    trailersExpectation.fulfill()
                }
            }

            XCTAssertEqual(XCTWaiter().wait(for: [
                headersExpectation, messageExpectation, trailersExpectation,
            ], timeout: kTimeout, enforceOrder: true), .completed)
        }
    }

    func testStatusCodeAndMessage() async {
        let message = Connectrpc_Conformance_V1_SimpleRequest.with { proto in
            proto.responseStatus = .with { status in
                status.code = Int32(Code.unknown.rawValue)
                status.message = "test status message"
            }
        }

        await self.executeTestWithClients { client in
            let response = await client.unaryCall(request: message)
            XCTAssertEqual(response.error?.code, .unknown)
            XCTAssertEqual(response.error?.message, "test status message")
        }
    }

    func testSpecialStatus() async {
        let statusMessage =
        "\\t\\ntest with whitespace\\r\\nand Unicode BMP ☺ and non-BMP \\uD83D\\uDE08\\t\\n"
        let message = Connectrpc_Conformance_V1_SimpleRequest.with { proto in
            proto.responseStatus = .with { status in
                status.code = 2
                status.message = statusMessage
            }
        }

        await self.executeTestWithClients { client in
            let response = await client.unaryCall(request: message)
            XCTAssertEqual(response.error?.code, .unknown)
            XCTAssertEqual(response.error?.message, statusMessage)
        }
    }

    func testTimeoutOnSleepingServer() async throws {
        try await self.executeTestWithClients(timeout: 0.01) { client in
            let expectation = self.expectation(description: "Stream times out")
            let message = Connectrpc_Conformance_V1_StreamingOutputCallRequest.with { proto in
                proto.payload = .with { $0.body = Data(count: 271_828) }
                proto.responseParameters = [
                    .with { parameters in
                        parameters.size = 31_415
                        parameters.intervalUs = 50_000
                    },
                ]
            }
            let stream = client.streamingOutputCall()
            try stream.send(message)
            for await case .complete(let code, let error, _) in stream.results() {
                XCTAssertEqual(code, .deadlineExceeded)
                XCTAssertNotNil(error)
                expectation.fulfill()
            }

            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
        }
    }

    func testUnimplementedMethod() async throws {
        let validErrorMessages = [
            // connect-go
            "connectrpc.conformance.v1.TestService.UnimplementedCall is not implemented",
            // grpc-go
            "method UnimplementedCall not implemented",
        ]
        try await self.executeTestWithClients { client in
            let response = await client.unimplementedCall(
                request: SwiftProtobuf.Google_Protobuf_Empty()
            )
            XCTAssertEqual(response.code, .unimplemented)
            XCTAssertTrue(validErrorMessages.contains(try XCTUnwrap(response.error?.message)))
        }
    }

    func testUnimplementedServerStreamingMethod() async throws {
        let validErrorMessages = [
            // connect-go
            """
            connectrpc.conformance.v1.TestService.UnimplementedStreamingOutputCall is \
            not implemented
            """,
            // grpc-go
            "method UnimplementedStreamingOutputCall not implemented",
        ]
        try await self.executeTestWithClients { client in
            let expectation = self.expectation(description: "Stream completes")
            let stream = client.unimplementedStreamingOutputCall()
            try stream.send(SwiftProtobuf.Google_Protobuf_Empty())
            for await case .complete(let code, let error, _) in stream.results() {
                XCTAssertEqual(code, .unimplemented)
                XCTAssertTrue(validErrorMessages.contains(
                    try XCTUnwrap((error as? ConnectError)?.message)
                ))
                expectation.fulfill()
            }

            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
        }
    }

    func testUnimplementedService() async {
        await self.executeTestWithUnimplementedClients { client in
            let response = await client.unimplementedCall(
                request: SwiftProtobuf.Google_Protobuf_Empty()
            )
            XCTAssertEqual(response.code, .unimplemented)
            XCTAssertNotNil(response.error)
        }
    }

    func testUnimplementedServerStreamingService() async throws {
        try await self.executeTestWithUnimplementedClients { client in
            let expectation = self.expectation(description: "Stream completes")
            let stream = client.unimplementedStreamingOutputCall()
            try stream.send(SwiftProtobuf.Google_Protobuf_Empty())
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message:
                    XCTFail("Unexpectedly received message")

                case .complete(let code, _, _):
                    XCTAssertEqual(code, .unimplemented)
                    expectation.fulfill()
                }
            }

            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
        }
    }

    func testFailUnary() async {
        await self.executeTestWithClients { client in
            let expectedErrorDetail = Connectrpc_Conformance_V1_ErrorDetail.with { proto in
                proto.reason = "soirée 🎉"
                proto.domain = "connect-conformance"
            }
            let response = await client.failUnaryCall(
                request: Connectrpc_Conformance_V1_SimpleRequest()
            )
            XCTAssertEqual(response.error?.code, .resourceExhausted)
            XCTAssertEqual(response.error?.message, "soirée 🎉")
            XCTAssertEqual(response.error?.unpackedDetails(), [expectedErrorDetail])
        }
    }

    func testFailServerStreaming() async throws {
        try await self.executeTestWithClients { client in
            let expectedErrorDetail = Connectrpc_Conformance_V1_ErrorDetail.with { proto in
                proto.reason = "soirée 🎉"
                proto.domain = "connect-conformance"
            }
            let expectation = self.expectation(description: "Stream completes")
            let stream = client.failStreamingOutputCall()

            try stream.send(Connectrpc_Conformance_V1_StreamingOutputCallRequest())
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message:
                    XCTFail("Unexpectedly received message")

                case .complete(_, let error, _):
                    guard let connectError = error as? ConnectError else {
                        XCTFail("Expected ConnectError")
                        return
                    }

                    XCTAssertEqual(connectError.code, .resourceExhausted)
                    XCTAssertEqual(connectError.message, "soirée 🎉")
                    XCTAssertEqual(connectError.unpackedDetails(), [expectedErrorDetail])
                    expectation.fulfill()
                }
            }
            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
        }
    }

    func testFailServerStreamingAfterResponse() async throws {
        try await self.executeTestWithClients { client in
            let expectedErrorDetail = Connectrpc_Conformance_V1_ErrorDetail.with { proto in
                proto.reason = "soirée 🎉"
                proto.domain = "connect-conformance"
            }
            let sizes = [31_415, 9, 2_653, 58_979]
            let stream = client.failStreamingOutputCall()
            try stream.send(Connectrpc_Conformance_V1_StreamingOutputCallRequest.with { proto in
                proto.responseParameters = sizes.enumerated().map { index, size in
                    return .with { parameters in
                        parameters.size = Int32(size)
                        parameters.intervalUs = Int32(index * 10)
                    }
                }
            })
            let expectation = self.expectation(description: "Stream completes")
            var responseCount = 0
            for await result in stream.results() {
                switch result {
                case .headers:
                    continue

                case .message(let output):
                    XCTAssertEqual(output.payload.body.count, sizes[responseCount])
                    responseCount += 1

                case .complete(_, let error, _):
                    guard let connectError = error as? ConnectError else {
                        XCTFail("Expected ConnectError")
                        return
                    }

                    XCTAssertEqual(connectError.code, .resourceExhausted)
                    XCTAssertEqual(connectError.message, "soirée 🎉")
                    XCTAssertEqual(connectError.unpackedDetails(), [expectedErrorDetail])
                    expectation.fulfill()
                }
            }

            XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: kTimeout), .completed)
            XCTAssertEqual(responseCount, 4)
        }
    }
}
