"""
Coach RAG AI Engine - Example Usage
====================================

This demonstrates how to use the Coach RAG Engine standalone.
NOT integrated into the app flow yet - just for testing.

Run: python -m coach_rag_engine.example_usage
"""

import asyncio
import os
from dotenv import load_dotenv

from .engine import CoachRAGEngine
from .models import (
    PerformanceAnalysis,
    CoachPersonality,
    CoachEnergy,
    PaceTrend,
    HRTrend,
    FatigueLevel,
    TargetStatus
)


async def example_interval_strategy():
    """
    Example: Get adaptive strategy during interval coaching.
    
    Simulates a runner who:
    - Is at km 4.2 of a 10K
    - Pace is declining (started at 5:58, now at 6:45)
    - HR is rising (cardiac drift)
    - Fatigue is moderate
    - Slightly behind target pace
    """
    
    print("=" * 60)
    print("COACH RAG AI ENGINE - Example Usage")
    print("=" * 60)
    
    # Load environment variables
    load_dotenv()
    
    # Initialize engine (secrets handled by Edge Function)
    engine = CoachRAGEngine(
        supabase_url=os.getenv("SUPABASE_URL"),
        supabase_anon_key=os.getenv("SUPABASE_ANON_KEY")
    )
    
    try:
        # ====================================================================
        # SCENARIO 1: Cardiac Drift Detected
        # ====================================================================
        print("\n📊 SCENARIO 1: Cardiac Drift")
        print("-" * 40)
        
        perf_analysis_1 = PerformanceAnalysis(
            current_pace=6.75,  # 6:45 min/km
            target_pace=6.0,    # 6:00 min/km
            current_distance=4200,  # 4.2 km
            target_distance=10000,  # 10K
            elapsed_time=22 * 60,   # 22 minutes
            
            current_hr=156,
            average_hr=148,
            max_hr=185,
            current_zone=3,
            zone_percentages={1: 5, 2: 35, 3: 48, 4: 12, 5: 0},
            
            pace_trend=PaceTrend.DECLINING,
            hr_trend=HRTrend.RISING,
            fatigue_level=FatigueLevel.MODERATE,
            target_status=TargetStatus.SLIGHTLY_BEHIND,
            
            performance_summary="Pace declining 47s since km 1, HR rising",
            heart_zone_analysis="Zone 3 dominant (48%), cardiac drift detected",
            interval_trends="5:58 → 6:12 → 6:22 → 6:45 (positive splits)",
            injury_risk_signals=[],
            
            pace_deviation=12.5,
            completed_intervals=4,
            interval_paces=[5.97, 6.2, 6.37, 6.75]
        )
        
        strategy_1 = await engine.get_adaptive_strategy(
            performance_analysis=perf_analysis_1,
            personality=CoachPersonality.STRATEGIST,
            energy_level=CoachEnergy.MEDIUM,
            user_id="test-user-12345",
            run_id="test-run-001"
        )
        
        print(f"\n🎯 STRATEGY: {strategy_1.strategy_name}")
        print(f"📝 {strategy_1.strategy_text}")
        print(f"\n📋 Situation: {strategy_1.situation_summary}")
        print(f"🤔 Reason: {strategy_1.selection_reason}")
        print(f"📊 Confidence: {strategy_1.confidence_score:.0%}")
        print(f"🎯 Expected: {strategy_1.expected_outcome}")
        
        # ====================================================================
        # SCENARIO 2: High Fatigue, Injury Risk
        # ====================================================================
        print("\n\n📊 SCENARIO 2: High Fatigue + Injury Risk")
        print("-" * 40)
        
        perf_analysis_2 = PerformanceAnalysis(
            current_pace=7.2,   # 7:12 min/km (way slower)
            target_pace=6.0,
            current_distance=7500,  # 7.5 km
            target_distance=10000,
            elapsed_time=48 * 60,
            
            current_hr=172,
            average_hr=158,
            max_hr=185,
            current_zone=4,
            zone_percentages={1: 3, 2: 20, 3: 35, 4: 32, 5: 10},
            
            pace_trend=PaceTrend.DECLINING,
            hr_trend=HRTrend.SPIKING,
            fatigue_level=FatigueLevel.HIGH,
            target_status=TargetStatus.WAY_BEHIND,
            
            performance_summary="Significant pace decline, HR near max",
            heart_zone_analysis="Zone 4-5 for 42% of run - overexertion",
            interval_trends="Erratic: 6:02, 6:15, 6:45, 7:05, 7:30, 7:45, 7:12",
            injury_risk_signals=[
                "Pace declining while HR rising - possible overexertion",
                "Form breakdown likely (slower pace in higher zones)"
            ],
            
            pace_deviation=20.0,
            completed_intervals=7,
            interval_paces=[6.03, 6.25, 6.75, 7.08, 7.5, 7.75, 7.2]
        )
        
        strategy_2 = await engine.get_adaptive_strategy(
            performance_analysis=perf_analysis_2,
            personality=CoachPersonality.PACER,
            energy_level=CoachEnergy.LOW,
            user_id="test-user-12345",
            run_id="test-run-001"
        )
        
        print(f"\n🎯 STRATEGY: {strategy_2.strategy_name}")
        print(f"📝 {strategy_2.strategy_text}")
        print(f"\n📋 Situation: {strategy_2.situation_summary}")
        print(f"🤔 Reason: {strategy_2.selection_reason}")
        print(f"📊 Confidence: {strategy_2.confidence_score:.0%}")
        
        # ====================================================================
        # SCENARIO 3: Ahead of Target, Push Possible
        # ====================================================================
        print("\n\n📊 SCENARIO 3: Ahead of Target, Strong Performance")
        print("-" * 40)
        
        perf_analysis_3 = PerformanceAnalysis(
            current_pace=5.8,   # 5:48 min/km (faster than target)
            target_pace=6.0,
            current_distance=3000,  # 3 km
            target_distance=5000,   # 5K
            elapsed_time=17 * 60,
            
            current_hr=142,
            average_hr=138,
            max_hr=185,
            current_zone=3,
            zone_percentages={1: 8, 2: 45, 3: 42, 4: 5, 5: 0},
            
            pace_trend=PaceTrend.STABLE,
            hr_trend=HRTrend.STABLE,
            fatigue_level=FatigueLevel.LOW,
            target_status=TargetStatus.AHEAD,
            
            performance_summary="Running strong, 12 seconds ahead of target",
            heart_zone_analysis="Zone 2-3 ideal distribution, HR headroom",
            interval_trends="5:45, 5:50, 5:52 - consistent negative splits",
            injury_risk_signals=[],
            
            pace_deviation=-3.3,
            completed_intervals=3,
            interval_paces=[5.75, 5.83, 5.87]
        )
        
        strategy_3 = await engine.get_adaptive_strategy(
            performance_analysis=perf_analysis_3,
            personality=CoachPersonality.FINISHER,
            energy_level=CoachEnergy.HIGH,
            user_id="test-user-12345",
            run_id="test-run-001"
        )
        
        print(f"\n🎯 STRATEGY: {strategy_3.strategy_name}")
        print(f"📝 {strategy_3.strategy_text}")
        print(f"\n📋 Situation: {strategy_3.situation_summary}")
        print(f"🤔 Reason: {strategy_3.selection_reason}")
        print(f"📊 Confidence: {strategy_3.confidence_score:.0%}")
        
        # ====================================================================
        # SELF-LEARNING: Record Outcome
        # ====================================================================
        print("\n\n🔄 SELF-LEARNING: Recording Strategy Outcome")
        print("-" * 40)
        
        if strategy_1.execution_id:
            # Simulate metrics after strategy was applied
            before_metrics = {"pace": 6.75, "hr": 156, "zone": 3}
            after_metrics = {"pace": 6.55, "hr": 152, "zone": 3}  # Improved!
            
            was_effective, score, reason = await engine.assess_strategy_effectiveness(
                execution_id=strategy_1.execution_id,
                before_metrics=before_metrics,
                after_metrics=after_metrics
            )
            
            print(f"✅ Strategy effectiveness assessed:")
            print(f"   Was effective: {was_effective}")
            print(f"   Score: {score:.0%}")
            print(f"   Reason: {reason}")
        
        print("\n" + "=" * 60)
        print("Example complete! Coach RAG Engine is working.")
        print("=" * 60)
        
    finally:
        await engine.close()


async def example_strategy_library():
    """Print the default strategy library that gets seeded."""
    
    print("\n📚 DEFAULT STRATEGY LIBRARY")
    print("=" * 60)
    
    strategies = [
        ("Cadence Reset", "pace_decline, form_breakdown", 
         "Quick feet, light steps. Count to 180. Shorten stride, find your rhythm."),
        
        ("Active Recovery Segment", "pace_decline, fatigue_high", 
         "Next 500m: easy pace, Zone 2 only. Shake out arms, breathe deep. Recharge."),
        
        ("Mental Reset Push", "pace_decline, motivation_boost", 
         "Dig deep! This is where champions are made. 30 seconds of focus!"),
        
        ("Zone Control Breathing", "hr_rising, zone_too_high", 
         "Inhale 3, exhale 3. Slow it down. Drop to Zone 3. Let HR settle."),
        
        ("Cardiac Drift Management", "cardiac_drift", 
         "Classic drift pattern. Ease 15 sec/km for next 500m. Focus on efficiency."),
        
        ("HR Headroom Push", "hr_stable, push_possible", 
         "You have HR capacity! Zone 3-4 is your sweet spot now. Push pace 10 sec/km."),
        
        ("Gap Closing Protocol", "target_behind", 
         "You're behind but recoverable. Next km: pick up 10 sec/km. Controlled push."),
        
        ("Maintain Lead Strategy", "target_ahead", 
         "Ahead of target - smart running! Hold this pace, don't overextend."),
        
        ("Damage Control Mode", "target_way_behind, fatigue_high", 
         "Way behind target. New goal: finish strong. Focus on steady pace, good form."),
        
        ("Injury Prevention Protocol", "injury_risk", 
         "Warning signs detected. Ease pace immediately. Shorter strides, land softly."),
        
        ("Form Check Recovery", "form_breakdown", 
         "Form breaking down. Quick check: shoulders down, core tight, arms 90°."),
        
        ("Second Wind Protocol", "fatigue_moderate, motivation_boost", 
         "Push through the wall! Your body is adapting. 60 more seconds of discomfort."),
        
        ("Energy Conservation Mode", "fatigue_moderate, target_on_track", 
         "Conserve energy for final push. Cruise at current pace, Zone 3 max."),
        
        ("Zone 2 Base Building", "zone_optimal, fatigue_low", 
         "Lock into Zone 2. This is aerobic development time. Comfortable pace."),
        
        ("Zone 4 Threshold Push", "push_possible, fatigue_low", 
         "Threshold time! Zone 4 for next 400m. Hard but controlled.")
    ]
    
    for name, tags, text in strategies:
        print(f"\n🏷️  {name}")
        print(f"   Tags: {tags}")
        print(f"   → {text}")


if __name__ == "__main__":
    print("\nRunning Coach RAG Engine examples...\n")
    
    # Show strategy library
    asyncio.run(example_strategy_library())
    
    # Run interactive example
    asyncio.run(example_interval_strategy())


