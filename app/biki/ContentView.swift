//
//  ContentView.swift
//  biki
//
//  Created by Stepanus Imanuel on 09/08/26.
//

import SwiftUI

struct ContentView: View {
    @State private var bluetooth = BluetoothManager()

    var body: some View {
        VStack(spacing: 18) {
            Text(bluetooth.isConnected ? "ESP32 Terhubung" : "ESP32 Belum Terhubung")
                .font(.headline)
                .foregroundStyle(
                    bluetooth.isConnected ? .green : .red
                )

            Text(bluetooth.status)
                .foregroundStyle(.secondary)

            Text("\(bluetooth.reading.weightGrams, specifier: "%.2f") g")
                .font(.system(size: 42, weight: .bold))

            Text(bluetooth.reading.colorName)
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("RAW R: \(bluetooth.reading.red)")
                Text("RAW G: \(bluetooth.reading.green)")
                Text("RAW B: \(bluetooth.reading.blue)")
            }

            Text(
                bluetooth.reading.hxReady
                ? "HX711 siap"
                : "HX711 belum siap"
            )

            Text(
                bluetooth.reading.colorReady
                ? "TCS3200 siap"
                : "TCS3200 belum siap"
            )
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
