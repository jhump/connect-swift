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

import Foundation

/// Implementation of the gRPC-Web protocol as an interceptor.
/// https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md
final class GRPCWebInterceptor: Interceptor {
    private let config: ProtocolClientConfig
    private let streamResponseHeaders = Locked<Headers?>(nil)

    init(config: ProtocolClientConfig) {
        self.config = config
    }
}

extension GRPCWebInterceptor: UnaryInterceptor {
    @Sendable
    func handleUnaryRawRequest(
        _ request: HTTPRequest<Data?>,
        proceed: @escaping (Result<HTTPRequest<Data?>, ConnectError>) -> Void
    ) {
        // gRPC-Web unary payloads are enveloped.
        let envelopedRequestBody = Envelope.packMessage(
            request.message ?? Data(), using: self.config.requestCompression
        )
        proceed(.success(HTTPRequest(
            url: request.url,
            headers: request.headers.addingGRPCHeaders(using: self.config, grpcWeb: true),
            message: envelopedRequestBody,
            method: request.method,
            trailers: nil,
            idempotencyLevel: request.idempotencyLevel
        )))
    }

    @Sendable
    func handleUnaryRawResponse(
        _ response: HTTPResponse,
        proceed: @escaping (HTTPResponse) -> Void
    ) {
        guard response.code == .ok else {
            // Invalid gRPC-Web response - expects HTTP 200. Potentially a network error.
            proceed(response)
            return
        }

        guard let responseData = response.message, !responseData.isEmpty else {
            let code = response.headers.grpcStatus() ?? response.code
            proceed(HTTPResponse(
                code: code,
                headers: response.headers,
                message: response.message,
                trailers: response.trailers,
                error: response.error ?? ConnectError.fromGRPCTrailers(
                    response.headers, code: code
                ),
                tracingInfo: response.tracingInfo
            ))
            return
        }

        let compressionPool = response.headers[HeaderConstants.grpcContentEncoding]?
            .first
            .flatMap { self.config.responseCompressionPool(forName: $0) }
        do {
            // gRPC Web returns data in 2 chunks (either/both of which may be compressed):
            // 1. OPTIONAL (when not trailers-only): The (headers and length prefixed)
            //    message data.
            // 2. The (headers and length prefixed) trailers data.
            // https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md
            let firstChunkLength = Envelope.messageLength(forPackedData: responseData)
            let prefixedFirstChunkLength = Envelope.prefixLength + firstChunkLength
            let firstChunk = try Envelope.unpackMessage(
                Data(responseData.prefix(upTo: prefixedFirstChunkLength)),
                compressionPool: compressionPool
            )
            let isTrailersOnly = 0b10000000 & firstChunk.headerByte != 0
            if isTrailersOnly {
                let unpackedTrailers = try Trailers.fromGRPCHeadersBlock(
                    firstChunk.unpacked
                )
                proceed(response.withHandledGRPCWebTrailers(unpackedTrailers, message: nil))
            } else {
                let trailersData = Data(responseData.suffix(from: prefixedFirstChunkLength))
                let unpackedTrailers = try Trailers.fromGRPCHeadersBlock(
                    try Envelope.unpackMessage(
                        trailersData, compressionPool: compressionPool
                    ).unpacked
                )
                proceed(response.withHandledGRPCWebTrailers(
                    unpackedTrailers,
                    message: firstChunk.unpacked
                ))
            }
        } catch let error {
            proceed(HTTPResponse(
                code: .unknown,
                headers: response.headers,
                message: response.message,
                trailers: response.trailers,
                error: error,
                tracingInfo: response.tracingInfo
            ))
        }
    }
}

extension GRPCWebInterceptor: StreamInterceptor {
    @Sendable
    func handleStreamStart(
        _ request: HTTPRequest<Void>,
        proceed: @escaping (Result<HTTPRequest<Void>, ConnectError>) -> Void
    ) {
        proceed(.success(HTTPRequest(
            url: request.url,
            headers: request.headers.addingGRPCHeaders(using: self.config, grpcWeb: true),
            message: request.message,
            method: request.method,
            trailers: nil,
            idempotencyLevel: request.idempotencyLevel
        )))
    }

    @Sendable
    func handleStreamRawInput(_ input: Data, proceed: @escaping (Data) -> Void) {
        proceed(Envelope.packMessage(input, using: self.config.requestCompression))
    }

    @Sendable
    func handleStreamRawResult(
        _ result: StreamResult<Data>,
        proceed: @escaping (StreamResult<Data>) -> Void
    ) {
        switch result {
        case .headers(let headers):
            if let grpcCode = headers.grpcStatus() {
                // Headers-only response.
                proceed(.complete(
                    code: grpcCode,
                    error: ConnectError.fromGRPCTrailers(headers, code: grpcCode),
                    trailers: headers
                ))
            } else {
                self.streamResponseHeaders.value = headers
                proceed(result)
            }

        case .message(let data):
            do {
                let responseCompressionPool = self.streamResponseHeaders.value?[
                    HeaderConstants.grpcContentEncoding
                ]?.first.flatMap { self.config.responseCompressionPool(forName: $0) }
                let (headerByte, unpackedData) = try Envelope.unpackMessage(
                    data, compressionPool: responseCompressionPool
                )
                let isTrailers = 0b10000000 & headerByte != 0
                if isTrailers {
                    let trailers = try Trailers.fromGRPCHeadersBlock(unpackedData)
                    let grpcCode = trailers.grpcStatus() ?? .unknown
                    if grpcCode == .ok {
                        proceed(.complete(code: .ok, error: nil, trailers: trailers))
                    } else {
                        proceed(.complete(
                            code: grpcCode,
                            error: ConnectError.fromGRPCTrailers(trailers, code: grpcCode),
                            trailers: trailers
                        ))
                    }
                } else {
                    proceed(.message(unpackedData))
                }
            } catch let error {
                // TODO: Close the stream here?
                proceed(.complete(code: .unknown, error: error, trailers: nil))
            }

        case .complete:
            proceed(result)
        }
    }
}

// MARK: - Private

private struct TrailersDecodingError: Error {}

private extension Trailers {
    static func fromGRPCHeadersBlock(_ source: Data) throws -> Self {
        guard let string = String(data: source, encoding: .utf8) else {
            throw TrailersDecodingError()
        }

        // Decode trailers based on gRPC Web spec:
        // https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md
        return string
            .split(separator: "\r\n")
            .reduce(into: Trailers()) { trailers, line in
                guard let separatorIndex = line.firstIndex(of: ":") else {
                    return
                }

                let trailerName = String(line.prefix(upTo: separatorIndex)).lowercased()
                var trailerValue = String(line.suffix(from: separatorIndex + 1))
                if trailerValue.hasPrefix(" ") {
                    trailerValue.removeFirst()
                }
                trailers[trailerName] = trailerValue
                    .split(separator: ",")
                    .map { String($0) }
            }
    }
}

private extension HTTPResponse {
    func withHandledGRPCWebTrailers(_ trailers: Trailers, message: Data?) -> Self {
        let grpcStatus = trailers.grpcStatus() ?? .unknown
        if grpcStatus == .ok {
            return HTTPResponse(
                code: grpcStatus,
                headers: self.headers,
                message: message,
                trailers: trailers,
                error: nil,
                tracingInfo: self.tracingInfo
            )
        } else {
            return HTTPResponse(
                code: grpcStatus,
                headers: self.headers,
                message: message,
                trailers: trailers,
                error: ConnectError.fromGRPCTrailers(trailers, code: grpcStatus),
                tracingInfo: self.tracingInfo
            )
        }
    }
}
