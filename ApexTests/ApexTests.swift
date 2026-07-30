//
//  ApexTests.swift
//  ApexTests
//
//  Created by Kai Bergman on 7/29/26.
//

import Testing
@testable import Apex

struct ApexTests {

    @Test func straightRouteProducesNoCalls() async throws {
        let route = (0..<20).map { Coordinate(Double($0) * 0.0002, 47.0) }
        #expect(PaceNotesCore.analyzeCurves(route).isEmpty)
    }

    @Test func routeDistanceIsOrdered() async throws {
        let route = [Coordinate(-122.0, 47.0), Coordinate(-121.999, 47.0), Coordinate(-121.998, 47.0005), Coordinate(-121.997, 47.001)]
        let curves = PaceNotesCore.analyzeCurves(route)
        #expect(curves == curves.sorted { $0.routeStartMeters < $1.routeStartMeters })
    }

}
