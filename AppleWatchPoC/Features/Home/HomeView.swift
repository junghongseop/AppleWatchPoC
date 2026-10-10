import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("녹음 · 워치 동기화") {
                    RecordingSyncView()
                }
                NavigationLink("소음·거리 음성 기록 테스트") {
                    SpeechTestView()
                }
            }
            .navigationTitle("기술 검증")
        }
    }
}
