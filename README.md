# RunbotAIWatch - Next-Gen Apple Watch Running Coach

A revolutionary voice-first running assistant for Apple Watch, powered by AI coaching and real-time voice feedback. RunbotAIWatch is a companion app to the Runbot iOS app, offering a fully voice-led experience optimized for wrist interaction.

## Features

### 🎤 Voice-First Interface
- **Real-time voice coaching**: AI-powered guidance during your run
- **Scheduled AI feedback**: Automatic coaching tips every 5 minutes (auto-terminates after 20s)
- **Voice selection**: Choose between Apple Samantha or GPT-4 Mini voice synthesis
- **Natural conversation**: Voice-led interactions for hands-free experience

### 📊 Running Stats
- **Tile-based display**: Distance, pace, calories, elevation on quick-access tiles
- **Real-time updates**: Live stats during active run
- **Visual feedback**: Runbot infinity logo animation during coaching

### 🎮 Run Controls
- **Start/Stop**: One-tap run control
- **Session management**: Automatic termination of all AI sessions on stop or logout
- **Safety protocols**: All AI coaching ends immediately when user stops

### ⚙️ Settings
- **Coach Personality**: Select from different coaching styles
- **Coach Energy**: Adjust coaching intensity (Low/Medium/High)
- **Voice AI**: Switch between Apple Samantha and GPT-4 Mini
- **Session preferences**: Customize feedback frequency and intensity

## Architecture

### Separate Codebase Strategy
- **Complete isolation**: No dependencies on Runbot iOS code
- **Shared backends**: Uses same Supabase and AI services
- **Clean separation**: Easy to manage and update independently
- **Companion connectivity**: Optional Watch Connectivity when paired with iOS app

### Project Structure
```
RunbotAIWatch/
├── RunbotAIWatch/                 # Main app target
│   ├── RunbotAIWatchApp.swift     # App entry point
│   ├── Views/                     # SwiftUI views
│   │   ├── ContentView.swift
│   │   ├── RunningView.swift
│   │   ├── StatsView.swift
│   │   ├── SettingsView.swift
│   │   └── AuthView.swift
│   ├── Models/                    # Data models
│   │   ├── RunDataModels.swift
│   │   ├── AICoachManager.swift
│   │   ├── VoiceManager.swift
│   │   └── UserPreferences.swift
│   ├── Services/                  # Backend services
│   │   ├── SupabaseService.swift
│   │   ├── OpenAIService.swift
│   │   └── LocationService.swift
│   ├── Assets.xcassets/           # Images, animations
│   └── Config.plist               # Configuration
├── Runbot AI WatchKit Extension/  # WatchKit extension (if needed)
└── Runbot AI Watch.app/           # Watch app bundle

## Safety & Compliance

### AI Session Safety
- ✅ All AI sessions terminate when user taps Stop
- ✅ All AI sessions terminate on logout
- ✅ Scheduled coaching auto-terminates after 20 seconds
- ✅ Voice synthesis stops immediately on interruption
- ✅ Memory is cleared between sessions

### Data Privacy
- Uses same Supabase authentication as iOS app
- Encrypted communication with AI services
- No personal data stored locally on watch
- Session data synced to secure backend

## Setup

### Requirements
- watchOS 9.0+
- Xcode 15.0+
- Swift 5.9+
- Supabase account (shared with iOS app)
- OpenAI API key (shared with iOS app)

### Installation

1. **Clone repository** (or create in Xcode)
   ```bash
   # This is a separate project
   cd /Users/ranga/Desktop/Runbot/RunbotAIWatch
   ```

2. **Open project**
   ```bash
   open RunbotAIWatch.xcodeproj
   ```

3. **Configure**
   - Copy `Config.plist.template` to `Config.plist`
   - Add your Supabase credentials
   - Add your OpenAI API key

4. **Build & Run**
   - Select "RunbotAIWatch (Watch) - WatchKit App" scheme
   - Choose Apple Watch simulator or device
   - Build and run

## Configuration

### Config.plist
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <key>SUPABASE_URL</key>
    <string>your_supabase_url</string>
    <key>SUPABASE_KEY</key>
    <string>your_supabase_key</string>
    <key>OPENAI_API_KEY</key>
    <string>your_openai_key</string>
</dict>
</plist>
```

## Usage

### Starting a Run
1. **Tap Start** on main screen
2. Watch begins tracking GPS and stats
3. Runbot animates with coaching feedback

### During Run
- **Voice feedback**: Listen to AI coaching every 5 minutes
- **Quick stats**: Swipe to view running metrics
- **Adjust settings**: Tap settings icon (if needed mid-run)

### Ending a Run
1. **Tap Stop** - immediately ends all AI sessions
2. Confirms run saved to Supabase
3. Returns to main screen

### Settings
- **Tap Settings icon** from main screen
- Adjust coach personality, energy, and voice preference
- Changes apply immediately

## Development Notes

### Voice Management
- Uses AVSpeechSynthesizer for Apple Samantha
- Uses OpenAI TTS for GPT-4 Mini voice option
- All voice is non-interruptible during playback for safety

### AI Coaching Logic
- Uses same prompt system as iOS app
- Scheduled feedback fires every 5 minutes during active run
- Feedback automatically stops after 20 seconds
- Safety: All voice/text generation stops on Stop button

### Running Stats
- Updates every 2 seconds during active run
- Uses Core Location for GPS data
- Stores in Supabase for sync with iOS app

## Performance Optimization

- **Minimal CPU**: Efficient voice processing
- **Battery conscious**: Optimized location updates
- **Network efficient**: Batches stats updates
- **Memory efficient**: Clears sessions immediately

## Support & Troubleshooting

### App Won't Start
- Verify Config.plist is present and valid
- Check Supabase credentials
- Ensure watchOS version is 9.0 or higher

### Voice Not Working
- Check speaker volume (not muted)
- Verify VoiceManager is initialized
- Try switching voice preference in Settings

### Stats Not Updating
- Verify location permission is granted
- Check GPS signal strength
- Restart app if needed

## Future Enhancements

- [ ] Companion app connectivity (iOS ↔ Watch sync)
- [ ] Custom coaching prompts
- [ ] Music integration
- [ ] Advanced metrics (VO2 Max, training load)
- [ ] Social features (leaderboards, challenges)
- [ ] Haptic feedback integration

## License

Same as Runbot iOS app

## Support

For issues or feature requests, contact: support@runbotapp.com

---

**Separate Codebase for Easy Management** ✨  
RunbotAIWatch maintains complete independence from Runbot iOS while sharing backend services.
