"""
Data Models for Coach RAG AI Engine
====================================

Defines all data structures used by the coaching strategy engine.
"""

from dataclasses import dataclass, field
from typing import List, Dict, Optional, Any
from enum import Enum
from datetime import datetime


# ============================================================================
# ENUMS
# ============================================================================

class CoachPersonality(Enum):
    STRATEGIST = "strategist"
    PACER = "pacer"
    FINISHER = "finisher"


class CoachEnergy(Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class PaceTrend(Enum):
    IMPROVING = "improving"
    STABLE = "stable"
    DECLINING = "declining"
    ERRATIC = "erratic"


class HRTrend(Enum):
    STABLE = "stable"
    RISING = "rising"
    SPIKING = "spiking"
    RECOVERING = "recovering"


class FatigueLevel(Enum):
    NONE = "none"
    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"
    SEVERE = "severe"


class TargetStatus(Enum):
    AHEAD = "ahead"
    ON_TRACK = "on_track"
    SLIGHTLY_BEHIND = "slightly_behind"
    WAY_BEHIND = "way_behind"


# ============================================================================
# INPUT MODELS
# ============================================================================

@dataclass
class PerformanceAnalysis:
    """
    Input from Performance RAG Analysis.
    This is the output of the existing Performance RAG system.
    """
    # Current run state
    current_pace: float  # min/km
    target_pace: float  # min/km
    current_distance: float  # meters
    target_distance: float  # meters
    elapsed_time: float  # seconds
    
    # Heart rate data
    current_hr: Optional[int] = None
    average_hr: Optional[int] = None
    max_hr: Optional[int] = None
    current_zone: Optional[int] = None
    zone_percentages: Dict[int, float] = field(default_factory=dict)
    
    # Trends and patterns
    pace_trend: PaceTrend = PaceTrend.STABLE
    hr_trend: HRTrend = HRTrend.STABLE
    fatigue_level: FatigueLevel = FatigueLevel.NONE
    target_status: TargetStatus = TargetStatus.ON_TRACK
    
    # Analysis outputs (from Performance RAG)
    performance_summary: str = ""
    heart_zone_analysis: str = ""
    interval_trends: str = ""
    hr_variation_analysis: str = ""
    injury_risk_signals: List[str] = field(default_factory=list)
    adaptive_microstrategy: str = ""
    
    # Pace deviation (percentage)
    pace_deviation: float = 0.0
    
    # Interval data
    completed_intervals: int = 0
    interval_paces: List[float] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "current_pace": self.current_pace,
            "target_pace": self.target_pace,
            "current_distance": self.current_distance,
            "target_distance": self.target_distance,
            "elapsed_time": self.elapsed_time,
            "current_hr": self.current_hr,
            "average_hr": self.average_hr,
            "max_hr": self.max_hr,
            "current_zone": self.current_zone,
            "zone_percentages": self.zone_percentages,
            "pace_trend": self.pace_trend.value,
            "hr_trend": self.hr_trend.value,
            "fatigue_level": self.fatigue_level.value,
            "target_status": self.target_status.value,
            "performance_summary": self.performance_summary,
            "heart_zone_analysis": self.heart_zone_analysis,
            "interval_trends": self.interval_trends,
            "hr_variation_analysis": self.hr_variation_analysis,
            "injury_risk_signals": self.injury_risk_signals,
            "adaptive_microstrategy": self.adaptive_microstrategy,
            "pace_deviation": self.pace_deviation,
            "completed_intervals": self.completed_intervals,
            "interval_paces": self.interval_paces
        }


@dataclass
class SituationContext:
    """
    Derived situation context for strategy matching.
    Built from PerformanceAnalysis + personality + energy.
    """
    # Core situation
    pace_trend: PaceTrend
    hr_trend: HRTrend
    fatigue_level: FatigueLevel
    target_status: TargetStatus
    
    # Derived flags
    cardiac_drift: bool = False  # pace declining + HR rising
    zone_too_high: bool = False  # >25% in Zone 4-5
    injury_risk: bool = False
    form_breakdown: bool = False
    push_possible: bool = False  # has HR headroom and low fatigue
    recovery_needed: bool = False
    
    # Coach parameters
    personality: CoachPersonality = CoachPersonality.STRATEGIST
    energy_level: CoachEnergy = CoachEnergy.MEDIUM
    
    # Relevant tags for strategy filtering
    situation_tags: List[str] = field(default_factory=list)
    
    def build_tags(self) -> List[str]:
        """Build situation tags for strategy filtering."""
        tags = []
        
        # Pace trend tags
        if self.pace_trend == PaceTrend.DECLINING:
            tags.append("pace_decline")
        elif self.pace_trend == PaceTrend.STABLE:
            tags.append("pace_stable")
        elif self.pace_trend == PaceTrend.IMPROVING:
            tags.append("pace_improving")
        
        # HR trend tags
        if self.hr_trend == HRTrend.RISING:
            tags.append("hr_rising")
        elif self.hr_trend == HRTrend.STABLE:
            tags.append("hr_stable")
        elif self.hr_trend == HRTrend.SPIKING:
            tags.append("hr_spiking")
        
        # Target status tags
        if self.target_status == TargetStatus.AHEAD:
            tags.append("target_ahead")
        elif self.target_status == TargetStatus.ON_TRACK:
            tags.append("target_on_track")
        elif self.target_status in [TargetStatus.SLIGHTLY_BEHIND, TargetStatus.WAY_BEHIND]:
            tags.append("target_behind")
        
        # Fatigue tags
        if self.fatigue_level == FatigueLevel.LOW:
            tags.append("fatigue_low")
        elif self.fatigue_level == FatigueLevel.MODERATE:
            tags.append("fatigue_moderate")
        elif self.fatigue_level in [FatigueLevel.HIGH, FatigueLevel.SEVERE]:
            tags.append("fatigue_high")
        
        # Derived condition tags
        if self.cardiac_drift:
            tags.append("cardiac_drift")
        if self.zone_too_high:
            tags.append("zone_too_high")
        if self.injury_risk:
            tags.append("injury_risk")
        if self.form_breakdown:
            tags.append("form_breakdown")
        if self.push_possible:
            tags.append("push_possible")
        if self.recovery_needed:
            tags.append("recovery_needed")
        
        self.situation_tags = tags
        return tags


# ============================================================================
# STRATEGY MODELS
# ============================================================================

@dataclass
class CoachingStrategy:
    """
    A coaching strategy retrieved from the database.
    """
    id: str
    strategy_name: str
    strategy_text: str
    strategy_context: Optional[str] = None
    tags: List[str] = field(default_factory=list)
    trigger_conditions: Dict[str, Any] = field(default_factory=dict)
    
    # Effectiveness metrics
    times_used: int = 0
    success_rate: float = 0.0
    avg_effectiveness_score: float = 0.0
    
    # Retrieval metadata
    similarity_score: float = 0.0
    source: str = "database"  # "database", "mem0", "ai_generated"


@dataclass
class StrategyExecution:
    """
    Records a strategy execution for self-learning.
    """
    id: Optional[str] = None
    user_id: str = ""
    run_id: Optional[str] = None
    strategy_id: Optional[str] = None
    
    # Context at execution
    execution_context: Dict[str, Any] = field(default_factory=dict)
    strategy_delivered: str = ""
    
    # Outcome (filled in later)
    outcome_measured: bool = False
    outcome_metrics: Dict[str, Any] = field(default_factory=dict)
    was_effective: Optional[bool] = None
    effectiveness_score: Optional[float] = None
    effectiveness_reason: Optional[str] = None
    
    # Timestamps
    executed_at: Optional[datetime] = None
    outcome_measured_at: Optional[datetime] = None


# ============================================================================
# OUTPUT MODELS
# ============================================================================

@dataclass
class AdaptiveStrategyOutput:
    """
    The final output of the Coach RAG Engine.
    Short, actionable strategy adapted to the situation.
    """
    # Primary strategy
    strategy_text: str  # The actual coaching text (short, actionable)
    strategy_name: str  # Name/type of strategy
    
    # Reasoning
    situation_summary: str  # Brief summary of detected situation
    selection_reason: str  # Why this strategy was chosen
    
    # Source strategies (what was combined)
    source_strategies: List[CoachingStrategy] = field(default_factory=list)
    mem0_insights_used: List[str] = field(default_factory=list)
    
    # Execution tracking
    execution_id: Optional[str] = None  # For outcome tracking later
    
    # Metadata
    confidence_score: float = 0.0  # 0-1, how confident in this strategy
    priority_tags: List[str] = field(default_factory=list)  # What this strategy addresses
    
    # Monitoring flags
    requires_outcome_check: bool = True  # Should check if this worked
    expected_outcome: str = ""  # What we expect to see if strategy works
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "strategy_text": self.strategy_text,
            "strategy_name": self.strategy_name,
            "situation_summary": self.situation_summary,
            "selection_reason": self.selection_reason,
            "confidence_score": self.confidence_score,
            "priority_tags": self.priority_tags,
            "expected_outcome": self.expected_outcome,
            "execution_id": self.execution_id
        }


# ============================================================================
# MEM0 MODELS
# ============================================================================

@dataclass
class Mem0CoachingMemory:
    """
    A coaching memory from Mem0.
    """
    memory_id: str
    memory_text: str
    category: str
    relevance_score: float = 0.0
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    # Extracted insights
    what_worked: Optional[str] = None
    what_didnt_work: Optional[str] = None
    runner_preference: Optional[str] = None



