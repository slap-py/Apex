//
//  ApexApp.swift
//  Apex
//
//  Created by Kai Bergman on 7/29/26.
//

import SwiftUI
import CoreData

@main
struct ApexApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
