//
//  ApexApp.swift
//  Apex
//
//  Created by Kai Bergman on 7/29/26.
//

import SwiftUI
import CoreData
import MapboxMaps

@main
struct ApexApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        let token = (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String)
        if let token, !token.isEmpty, !token.hasPrefix("$(") {
            MapboxOptions.accessToken = token
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
