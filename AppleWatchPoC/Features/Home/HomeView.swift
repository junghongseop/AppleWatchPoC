import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("녹음 · 워치 동기화") {
                    RecordingSyncView()
                }
            }
            .navigationTitle("기술 검증")
        }
    }
}
