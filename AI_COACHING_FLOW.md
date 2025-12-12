# AI Coaching Feedback Flow - Complete Logic & Process

## Overview
The RunbotAI Watch app provides **three types of AI coaching feedback** during a run:
1. **Start-of-Run Coaching** - Personalized welcome and strategy
2. **Interval Coaching** - Periodic feedback every N km (based on `feedbackFrequency`)
3. **End-of-Run Coaching** - Comprehensive performance analysis

---

## 🏁 1. START-OF-RUN COACHING

### **Trigger:**
- Called **once** when run starts
- Triggered **3 seconds after** user taps "Start Run" button
- Location: `MainRunbotView.swift` line 451-460

### **Process Flow:**

```
User taps "Start Run"
  ↓
RunTracker.startRun() called
  ↓
3 second delay (allows GPS to initialize)
  ↓
aiCoach.startOfRunCoaching() called
  ↓
┌─────────────────────────────────────────┐
│ 1. Fetch Mem0 Insights & Runner Name    │
│    - Searches Mem0 for runner profile   │
│    - Extracts runner name from history  │
│    - Fetches performance insights       │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 2. Initialize RAG Analyzer Cache       │
│    - Caches user preferences           │
│    - Caches language settings           │
│    - Caches Mem0 insights              │
│    - This cache persists for entire run │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 3. Fetch Run Aggregates                 │
│    - Gets average distance, pace        │
│    - Gets best pace from history        │
│    - Gets total run count               │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 4. Generate Coaching Feedback           │
│    - Builds personalized prompt         │
│    - Includes: name, last run stats,     │
│      target pace, heart zone advice,    │
│      race strategy                      │
│    - Calls OpenAI GPT-4o-mini          │
│    - Max 60 words                       │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 5. Deliver Feedback via Voice           │
│    - Maps voiceAIModel to voiceOption   │
│    - Uses OpenAI TTS if GPT-4 selected │
│    - Uses Apple TTS if Apple selected   │
│    - Auto-terminates after 60 seconds   │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 6. Persist to Database                  │
│    - Saves to Supabase coaching_sessions│
│    - Saves to Mem0 (start strategy)     │
└─────────────────────────────────────────┘
```

### **Prompt Structure:**
- **Personality-specific instructions** (Strategist/Pacer/Finisher)
- **Energy level** (Low/Medium/High)
- **Personalization:**
  - Runner's name
  - Last run performance
  - Target pace awareness
  - Heart zone guidance
  - Race strategy (pacing plan)
- **Mem0 insights** (historical performance)
- **Run aggregates** (average stats)

### **Example Output:**
> "Hey Sarah! Your last run was solid at 6:45 pace. Today, target 6:30. Start in Zone 2, build to Zone 3 by km 2. First km easy, then lock in. You've got this!"

---

## 🎯 2. INTERVAL COACHING (Every N km)

### **Trigger:**
- Triggered by **distance milestones** (not time-based)
- Based on `feedbackFrequency` setting (1, 2, 5, or 10 km)
- Location: `MainRunbotView.swift` line 318-352

### **Trigger Logic:**
```swift
let km = Int(stats.distance / 1000.0)  // Current distance in km
let freq = userPreferences.settings.feedbackFrequency  // e.g., 1, 2, 5, 10
if freq > 0, km > lastCoachingKm, km % freq == 0 {
    // Trigger interval coaching
    aiCoach.startScheduledCoaching(...)
    lastCoachingKm = km
}
```

**Example:**
- If `feedbackFrequency = 1`: Coaching at 1km, 2km, 3km, 4km...
- If `feedbackFrequency = 2`: Coaching at 2km, 4km, 6km, 8km...
- If `feedbackFrequency = 5`: Coaching at 5km, 10km, 15km...

### **Process Flow:**

```
Distance milestone reached (e.g., 2km, 5km)
  ↓
.onReceive(runTracker.$statsUpdate) detects milestone
  ↓
aiCoach.startScheduledCoaching() called
  ↓
┌─────────────────────────────────────────┐
│ 1. Fetch Mem0 Insights & Runner Name    │
│    - Fresh search for latest insights  │
│    - May include recent coaching       │
│      feedback from this run             │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 2. RAG Performance Analysis (CRITICAL)   │
│    - Analyzes current performance        │
│    - Compares to target pace            │
│    - Analyzes heart rate zones          │
│    - Detects trends (pace dropping?)   │
│    - Identifies injury risks            │
│    - Provides adaptive microstrategy    │
│    - Returns LLM context for prompt     │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 3. Generate Coaching Feedback           │
│    - Builds prompt with RAG analysis    │
│    - Includes: current pace, target,   │
│      zone status, trends, recommendations│
│    - Calls OpenAI GPT-4o-mini          │
│    - Max 60 words                       │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 4. Deliver Feedback via Voice           │
│    - Uses selected voice AI model       │
│    - Auto-terminates after 60 seconds   │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 5. Persist to Database                  │
│    - Saves to Supabase coaching_sessions│
│    - Saves to Mem0 (ai_coaching_feedback)│
│    - This feedback becomes available    │
│      for next interval's Mem0 search    │
└─────────────────────────────────────────┘
```

### **RAG Analysis Components:**
The RAG analyzer provides:
- **Target Status**: On target / Behind / Ahead
- **Zone Analysis**: Current zone, time in zones, efficiency
- **Pace Trends**: Is pace dropping? Improving?
- **Injury Risk Signals**: Overexertion warnings
- **Adaptive Microstrategy**: Specific recommendations
- **LLM Context**: Formatted for prompt inclusion

### **Prompt Structure:**
- **RAG Analysis Context** (if available)
- **Current stats**: Distance, pace, target comparison
- **Personality-specific instructions**
- **Energy level**
- **Mem0 insights** (may include recent feedback)
- **Actionable coaching** based on RAG recommendations

### **Example Output:**
> "Sarah, you're 8% behind target but HR is stable in Zone 3. Pick up cadence to 180 - you have headroom. Next km: push to Zone 4 briefly."

---

## 🏁 3. END-OF-RUN COACHING

### **Trigger:**
- Called **once** when user taps "Stop Run" button
- Location: `MainRunbotView.swift` line 1705-1711
- Triggered **1 second after** run stops (allows final stats update)

### **Process Flow:**

```
User taps "Stop Run"
  ↓
runTracker.forceFinalStatsUpdate() - captures latest stats
  ↓
aiCoach.stopCoaching() - stops any ongoing coaching
voiceManager.stopSpeaking() - stops any ongoing voice
  ↓
runTracker.stopRun() - stops GPS tracking
  ↓
1 second delay (ensures all data is captured)
  ↓
aiCoach.endOfRunCoaching() called
  ↓
┌─────────────────────────────────────────┐
│ 1. Fetch Mem0 Insights & Runner Name    │
│    - Final search for all insights     │
│    - Includes all coaching feedback     │
│      from this run                      │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 2. RAG End-of-Run Analysis              │
│    - Comprehensive performance review   │
│    - Target achievement assessment      │
│    - Zone distribution analysis         │
│    - Pace consistency analysis          │
│    - HealthKit data integration         │
│    - Returns detailed analysis context  │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 3. Generate End-of-Run Feedback         │
│    - Builds comprehensive prompt        │
│    - Includes: target assessment,       │
│      what went well, what needs work,   │
│      personal touch from Mem0           │
│    - Calls OpenAI GPT-4o-mini          │
│    - Max 60 words                       │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 4. Deliver Feedback via Voice           │
│    - Uses selected voice AI model       │
│    - Auto-terminates after 60 seconds   │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 5. Persist Comprehensive Summary         │
│    - Saves to Supabase coaching_sessions│
│    - Saves detailed summary to Mem0     │
│      (running_performance category)     │
│    - Includes: distance, pace, target, │
│      achievement status, feedback       │
└─────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────┐
│ 6. Clear RAG Cache                      │
│    - Run is complete                    │
│    - Cache cleared for next run         │
└─────────────────────────────────────────┘
```

### **Prompt Structure:**
- **RAG End-of-Run Analysis** (comprehensive)
- **Target Assessment**: Did they hit target?
- **What Went Well**: Specific positive with data
- **What Needs Work**: Critical improvement area
- **Personal Touch**: Mem0 history references
- **Personality & Energy**: Matched to preferences

### **Example Output:**
> "Sarah, 5K done in 32:15 - target hit! Your Zone 3 efficiency was solid at 48%. But those final 2km? Pace dropped 35 seconds - that's where you lost time. Next run: focus on even splits. Strong effort overall."

---

## 🔄 Key Components

### **1. Voice AI Model Selection**
- **User Setting**: `preferences.voiceAIModel` (`.openai` or `.apple`)
- **Mapping**: 
  - `.openai` → `VoiceOption.gpt4` → OpenAI TTS (via `openai-proxy` edge function)
  - `.apple` → `VoiceOption.samantha` → Apple TTS
- **Location**: `AICoachManager.deliverFeedback()` line 774-783

### **2. RAG Performance Analyzer**
- **Purpose**: Provides data-driven performance analysis
- **Inputs**: Stats, HealthKit data, intervals, preferences
- **Outputs**: Target status, zone analysis, trends, recommendations
- **Location**: `RAGPerformanceAnalyzer.swift`

### **3. Mem0 Integration**
- **Purpose**: Personalized insights from run history
- **Search**: Fetches relevant memories for context
- **Write**: Saves coaching feedback for future runs
- **Edge Function**: Uses `mem0-proxy` (shared with iOS)
- **Location**: `Mem0Manager.swift`

### **4. Auto-Termination Safety**
- **Timer**: 60-second auto-terminate for all coaching
- **Location**: `AICoachManager.startCoachingTimer()` line 313-333
- **Purpose**: Prevents infinite coaching loops

### **5. Distance-Based Triggering**
- **Not time-based**: Uses distance milestones
- **Formula**: `km % feedbackFrequency == 0`
- **Prevents duplicate**: Tracks `lastCoachingKm`
- **Location**: `MainRunbotView.swift` line 336-351

---

## 📊 Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    RUN START                                │
└─────────────────────────────────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  Start-of-Run Coaching          │
        │  - Mem0 insights                │
        │  - RAG cache init                │
        │  - Personalized welcome         │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  Run Active (GPS tracking)      │
        │  - Stats update every 2s        │
        │  - Distance milestones tracked  │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  Interval Coaching (Every N km) │
        │  - RAG performance analysis     │
        │  - Adaptive coaching            │
        │  - Saves to Mem0                │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  Run Active (continues)         │
        │  - Next milestone approaches   │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  Interval Coaching (repeats)   │
        │  - Fresh RAG analysis           │
        │  - May reference previous       │
        │    coaching from Mem0          │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  User Taps "Stop Run"           │
        └─────────────────────────────────┘
                          ↓
        ┌─────────────────────────────────┐
        │  End-of-Run Coaching            │
        │  - RAG end-of-run analysis      │
        │  - Comprehensive summary        │
        │  - Saves detailed summary       │
        │  - Clears RAG cache             │
        └─────────────────────────────────┘
```

---

## 🎯 Key Features

### **1. Personalization**
- Uses runner's name from Mem0
- References last run performance
- Incorporates historical insights
- Adapts to user preferences (personality, energy)

### **2. Data-Driven**
- RAG analysis provides real-time performance insights
- HealthKit integration (heart rate zones)
- Pace trend analysis
- Target achievement tracking

### **3. Adaptive**
- Coaching adjusts based on current performance
- Detects issues (pace dropping, overexertion)
- Provides specific, actionable recommendations
- References previous coaching from same run

### **4. Efficient**
- RAG cache initialized once at start
- Mem0 caching (10-minute TTL)
- Batched Mem0 writes (every 30 seconds)
- Distance-based triggering (not continuous polling)

### **5. Safe**
- 60-second auto-terminate for all coaching
- Stops immediately on "Stop Run"
- Prevents duplicate feedback
- Handles offline scenarios gracefully

---

## 🔧 Configuration

### **Feedback Frequency** (`feedbackFrequency`)
- **Settings**: 1, 2, 5, or 10 km
- **Default**: 1 km
- **Effect**: Determines how often interval coaching triggers
- **Location**: `UserPreferences.Settings.feedbackFrequency`

### **Coach Personality**
- **Options**: Strategist, Pacer, Finisher
- **Effect**: Changes coaching style and focus
- **Location**: `UserPreferences.Settings.coachPersonality`

### **Coach Energy**
- **Options**: Low, Medium, High
- **Effect**: Changes tone and verbosity
- **Location**: `UserPreferences.Settings.coachEnergy`

### **Voice AI Model**
- **Options**: Apple Samantha, OpenAI GPT-4 Mini
- **Effect**: Determines TTS engine used
- **Location**: `UserPreferences.Settings.voiceAIModel`

---

## 📝 Summary

The AI coaching system provides **three distinct coaching moments**:

1. **Start**: Personalized welcome with strategy (once)
2. **Intervals**: Data-driven adaptive coaching (every N km)
3. **End**: Comprehensive performance analysis (once)

All coaching:
- Uses **RAG analysis** for data-driven insights
- Incorporates **Mem0** for personalization
- Respects **user preferences** (personality, energy, voice)
- **Auto-terminates** after 60 seconds
- **Saves to database** for future reference

The system is **efficient** (caching, batching), **adaptive** (RAG-driven), and **personalized** (Mem0 integration).

