import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("전면 카메라 · 손동작 기록") {
                    HandTrackingView()
                }
                NavigationLink("워치 비접촉 백그라운드 제어") {
                    ContactlessView()
                }
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
