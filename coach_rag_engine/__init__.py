"""
Coach RAG AI Engine
====================

A separate, self-learning coaching strategy engine that uses:
- pgvector + Supabase for semantic strategy retrieval
- Mem0 for coaching memories and personalization
- Performance Analysis RAG output as context
- Coach personality + energy level for strategy adaptation

This engine is INDEPENDENT from the AI Coaching feedback system.
It can be integrated later but operates standalone.

Usage:
    from coach_rag_engine import CoachRAGEngine
    
    engine = CoachRAGEngine()
    strategy = await engine.get_adaptive_strategy(
        performance_analysis=perf_analysis,
        personality="strategist",
        energy_level="medium",
        user_id="user-uuid"
    )
"""

from .engine import CoachRAGEngine
from .models import (
    PerformanceAnalysis,
    CoachingStrategy,
    StrategyExecution,
    AdaptiveStrategyOutput,
    SituationContext
)

__version__ = "1.0.0"
__all__ = [
    "CoachRAGEngine",
    "PerformanceAnalysis",
    "CoachingStrategy",
    "StrategyExecution",
    "AdaptiveStrategyOutput",
    "SituationContext"
]



