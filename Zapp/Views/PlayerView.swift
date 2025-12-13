import SwiftUI

struct PlayerView: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 16) {
            // Preview thumbnail with play button
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(12)
                
                Button(action: { PlayerPresentationManager.shared.presentChannel(channel) }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundColor(.white)
                }
            }
            .padding()

            List {
                Section(header: Text("player_info_channel")) {
                    Text(channel.name).font(.title2)
                    if let subtitle = channel.subtitle { 
                        Text(subtitle).foregroundColor(.secondary) 
                    }
                }
                
                if let color = channel.color {
                    Section(header: Text("player_info_color")) {
                        HStack {
                            Circle()
                                .fill(Color(hex: color) ?? .gray)
                                .frame(width: 30, height: 30)
                            Text(color)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()
        }
        .navigationTitle(channel.name)
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        let ch = Channel(id: "demo", name: "Demo", stream_url: nil, logo_name: nil, color: nil, subtitle: nil)
        NavigationView {
            PlayerView(channel: ch)
        }
    }
}
