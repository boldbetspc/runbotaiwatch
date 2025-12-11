"""
Coach RAG AI Engine - Core Engine
==================================

The main engine that:
1. Retrieves top strategies via pgvector + tags from Supabase
2. Fetches Mem0 coaching memories for personalization
3. Takes Performance Analysis from Performance RAG as input
4. Considers coach personality + energy level
5. Determines adaptive strategy for the current situation
6. Tracks strategy execution for self-learning

This is SEPARATE from the AI Coaching feedback system.
Output is short, actionable coaching strategy.
"""

import os
import json
import asyncio
import httpx
from typing import List, Dict, Optional, Any, Tuple
from datetime import datetime

try:
    from .models import (
        PerformanceAnalysis,
        CoachingStrategy,
        StrategyExecution,
        AdaptiveStrategyOutput,
        SituationContext,
        Mem0CoachingMemory,
        CoachPersonality,
        CoachEnergy,
        PaceTrend,
        HRTrend,
        FatigueLevel,
        TargetStatus
    )
except ImportError:
    # Fallback for direct script execution
    from models import (
        PerformanceAnalysis,
        CoachingStrategy,
        StrategyExecution,
        AdaptiveStrategyOutput,
        SituationContext,
        Mem0CoachingMemory,
        CoachPersonality,
        CoachEnergy,
        PaceTrend,
        HRTrend,
        FatigueLevel,
        TargetStatus
    )


class CoachRAGEngine:
    """
    Coach RAG AI Engine
    
    A self-learning coaching strategy engine that combines:
    - Vector-based strategy retrieval (pgvector + Supabase)
    - Mem0 coaching memories for personalization
    - Performance analysis context
    - LLM-powered strategy adaptation
    
    Usage:
        engine = CoachRAGEngine()
        strategy = await engine.get_adaptive_strategy(
            performance_analysis=perf_analysis,
            personality=CoachPersonality.STRATEGIST,
            energy_level=CoachEnergy.MEDIUM,
            user_id="user-uuid"
        )
    """
    
    def __init__(
        self,
        supabase_url: Optional[str] = None,
        supabase_anon_key: Optional[str] = None
    ):
        """
        Initialize the Coach RAG Engine.
        
        Uses Supabase Edge Function for secure API calls.
        Secrets are stored in Edge Function environment (never exposed).
        
        Args:
            supabase_url: Supabase project URL
            supabase_anon_key: Supabase anon key (for Edge Function auth)
        """
        
        # Load Supabase credentials (required for Edge Function)
        self.supabase_url = supabase_url or os.getenv("SUPABASE_URL", "")
        self.supabase_anon_key = supabase_anon_key or os.getenv("SUPABASE_ANON_KEY", "")
        
        # Edge Function endpoint
        self.edge_function_url = f"{self.supabase_url}/functions/v1/coach-rag-strategy"
        
        # HTTP client for async requests
        self._client: Optional[httpx.AsyncClient] = None
        
        # Strategy cache (in-memory)
        self._strategy_cache: Dict[str, List[CoachingStrategy]] = {}
        self._cache_ttl = 300  # 5 minutes
        self._cache_timestamps: Dict[str, datetime] = {}
        
        # Execution tracking (for self-learning)
        self._pending_executions: Dict[str, StrategyExecution] = {}
        
        print("🏃 Coach RAG Engine initialized (using secure Edge Function)")
    
    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=30.0)
        return self._client
    
    async def close(self):
        """Close the HTTP client."""
        if self._client and not self._client.is_closed:
            await self._client.aclose()
    
    # ========================================================================
    # KB EMBEDDING GENERATION (for KB initialization/evolution)
    # ========================================================================
    
    async def generate_and_store_kb_embeddings(
        self,
        strategy_id: Optional[str] = None
    ) -> int:
        """
        Generate and store embeddings for KB strategies.
        If strategy_id is None, generates for all strategies missing embeddings.
        
        Note: Requires OPENAI_API_KEY in environment for embedding generation.
        
        Returns:
            Number of embeddings generated
        """
        
        # Load OpenAI key from environment (needed for embedding generation)
        openai_key = os.getenv("OPENAI_API_KEY", "")
        
        if not openai_key or not self.supabase_url or not self.supabase_anon_key:
            print("   ⚠️ Missing API keys for embedding generation")
            print("   Required: OPENAI_API_KEY (env), SUPABASE_URL, SUPABASE_ANON_KEY")
            return 0
        
        try:
            client = await self._get_client()
            
            # Get strategies that need embeddings
            if strategy_id:
                params = {"id": f"eq.{strategy_id}"}
            else:
                params = {"strategy_embedding": "is.null", "is_active": "eq.true"}
            
            response = await client.get(
                f"{self.supabase_url}/rest/v1/coaching_strategies_kb",
                headers={
                    "apikey": self.supabase_anon_key,
                    "Authorization": f"Bearer {self.supabase_anon_key}"
                },
                params=params
            )
            
            if response.status_code != 200:
                print(f"   ❌ Failed to fetch strategies: {response.status_code}")
                return 0
            
            strategies = response.json()
            if not strategies:
                print("   ✅ All strategies already have embeddings")
                return 0
            
            print(f"   🔄 Generating embeddings for {len(strategies)} strategies...")
            
            count = 0
            for strategy in strategies:
                # Build embedding text: title + conditions_to_use + strategy_text
                embedding_text = f"""
                Strategy: {strategy['title']}
                Use when: {strategy['conditions_to_use']}
                Avoid when: {strategy['when_not_to_use']}
                Strategy text: {strategy['strategy_text']}
                Distance: {strategy['distance']}
                Type: {strategy['type']}
                Runner level: {strategy['runner_level']}
                """.strip()
                
                # Generate embedding using OpenAI (from env)
                embedding = await self._generate_embedding_with_key(embedding_text, openai_key)
                
                if embedding:
                    # Store embedding via RPC
                    update_response = await client.post(
                        f"{self.supabase_url}/rest/v1/rpc/update_strategy_embedding_kb",
                        headers={
                            "apikey": self.supabase_anon_key,
                            "Authorization": f"Bearer {self.supabase_anon_key}",
                            "Content-Type": "application/json"
                        },
                        json={
                            "p_strategy_id": strategy['id'],
                            "p_embedding": embedding
                        }
                    )
                    
                    if update_response.status_code == 200:
                        count += 1
                        if count % 5 == 0:
                            print(f"   ✅ Generated {count}/{len(strategies)} embeddings...")
                    else:
                        print(f"   ⚠️ Failed to store embedding for {strategy['id']}")
            
            print(f"   ✅ Generated {count} embeddings successfully")
            return count
            
        except Exception as e:
            print(f"   ❌ Embedding generation error: {e}")
            import traceback
            traceback.print_exc()
            return 0
    
    # ========================================================================
    # MAIN API: Get Adaptive Strategy
    # ========================================================================
    
    async def get_adaptive_strategy(
        self,
        performance_analysis: PerformanceAnalysis,
        personality: CoachPersonality,
        energy_level: CoachEnergy,
        user_id: str,
        run_id: Optional[str] = None
    ) -> AdaptiveStrategyOutput:
        """
        Main entry point: Get adaptive coaching strategy for current situation.
        
        Args:
            performance_analysis: Output from Performance RAG system
            personality: Coach personality (strategist/pacer/finisher)
            energy_level: Coach energy (low/medium/high)
            user_id: User UUID for personalization
            run_id: Optional run UUID for tracking
            
        Returns:
            AdaptiveStrategyOutput with short, actionable strategy
        """
        print(f"🎯 Coach RAG: Analyzing situation for user {user_id[:8]}...")
        
        # 0. Call Edge Function (secrets handled securely server-side)
        if not self.supabase_url or not self.supabase_anon_key:
            raise ValueError("Supabase URL and anon key required for Edge Function")
        
        # 1. Build situation context from performance analysis
        context = self._build_situation_context(
            performance_analysis, 
            personality, 
            energy_level
        )
        print(f"   → Situation: {context.pace_trend.value} pace, {context.hr_trend.value} HR, {context.fatigue_level.value} fatigue")
        
        # 2. Call Edge Function to get strategy (secrets used internally)
        try:
            client = await self._get_client()
            
            response = await client.post(
                self.edge_function_url,
                headers={
                    "apikey": self.supabase_anon_key,
                    "Authorization": f"Bearer {self.supabase_anon_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "performance_analysis": performance_analysis.to_dict(),
                    "personality": personality.value,
                    "energy_level": energy_level.value,
                    "user_id": user_id,
                    "run_id": run_id
                }
            )
            
            if response.status_code == 200:
                result = response.json()
                strategy_data = result.get("strategy", {})
                
                adaptive_strategy = AdaptiveStrategyOutput(
                    strategy_text=strategy_data.get("strategy_text", "Maintain current effort."),
                    strategy_name=strategy_data.get("strategy_name", "Adaptive Strategy"),
                    situation_summary=strategy_data.get("situation_summary", f"{context.pace_trend.value} pace, {context.fatigue_level.value} fatigue"),
                    selection_reason=strategy_data.get("selection_reason", "Best match for current situation"),
                    confidence_score=strategy_data.get("confidence_score", 0.7),
                    priority_tags=context.situation_tags[:3],
                    expected_outcome=strategy_data.get("expected_outcome", "Improved performance"),
                    execution_id=strategy_data.get("execution_id")  # Edge Function records execution
                )
                
                print(f"   → Strategy: {adaptive_strategy.strategy_name} (confidence: {adaptive_strategy.confidence_score:.0%})")
                return adaptive_strategy
            else:
                error_text = await response.aread()
                print(f"   ❌ Edge Function error: {response.status_code} - {error_text.decode()}")
                raise Exception(f"Edge Function failed: {response.status_code}")
                
        except Exception as e:
            print(f"   ❌ Edge Function call error: {e}")
            # Fallback to simple strategy
            return AdaptiveStrategyOutput(
                strategy_text="Maintain current pace. Stay focused. You're doing well.",
                strategy_name="Fallback Strategy",
                situation_summary=f"{context.pace_trend.value} pace, {context.fatigue_level.value} fatigue",
                selection_reason="Edge Function unavailable",
                confidence_score=0.5,
                priority_tags=context.situation_tags[:3]
            )
    
    # ========================================================================
    # SITUATION CONTEXT BUILDER
    # ========================================================================
    
    def _build_situation_context(
        self,
        perf: PerformanceAnalysis,
        personality: CoachPersonality,
        energy: CoachEnergy
    ) -> SituationContext:
        """Build situation context from performance analysis."""
        
        # Detect cardiac drift (pace declining + HR rising)
        cardiac_drift = (
            perf.pace_trend == PaceTrend.DECLINING and 
            perf.hr_trend in [HRTrend.RISING, HRTrend.SPIKING]
        )
        
        # Detect zone too high (>25% in Zone 4-5)
        zone_45_pct = perf.zone_percentages.get(4, 0) + perf.zone_percentages.get(5, 0)
        zone_too_high = zone_45_pct > 25
        
        # Detect injury risk
        injury_risk = len(perf.injury_risk_signals) > 0
        
        # Detect form breakdown (pace declining but HR not rising = mechanical issue)
        form_breakdown = (
            perf.pace_trend == PaceTrend.DECLINING and 
            perf.hr_trend == HRTrend.STABLE
        )
        
        # Detect push possible (HR headroom + low fatigue)
        push_possible = (
            perf.fatigue_level in [FatigueLevel.NONE, FatigueLevel.LOW] and
            perf.hr_trend == HRTrend.STABLE and
            (perf.current_hr is None or perf.max_hr is None or 
             (perf.current_hr / perf.max_hr) < 0.85)
        )
        
        # Detect recovery needed
        recovery_needed = (
            perf.fatigue_level in [FatigueLevel.HIGH, FatigueLevel.SEVERE] or
            zone_too_high or
            cardiac_drift
        )
        
        context = SituationContext(
            pace_trend=perf.pace_trend,
            hr_trend=perf.hr_trend,
            fatigue_level=perf.fatigue_level,
            target_status=perf.target_status,
            cardiac_drift=cardiac_drift,
            zone_too_high=zone_too_high,
            injury_risk=injury_risk,
            form_breakdown=form_breakdown,
            push_possible=push_possible,
            recovery_needed=recovery_needed,
            personality=personality,
            energy_level=energy
        )
        
        # Build situation tags for filtering
        context.build_tags()
        
        return context
    
    # ========================================================================
    # STRATEGY RETRIEVAL (Next-Gen Vector RAG)
    # ========================================================================
    
    async def _retrieve_strategies(
        self,
        context: SituationContext,
        user_id: str,
        performance_analysis: PerformanceAnalysis
    ) -> List[CoachingStrategy]:
        """
        Next-gen RAG retrieval using:
        1. Vector semantic search (pgvector) - finds semantically similar strategies
        2. Distance + runner level filtering
        3. LLM-based condition matching (conditions_to_use / when_not_to_use)
        4. Success rate ordering (self-learning)
        """
        
        if not self.supabase_url or not self.supabase_key:
            print("   ⚠️ Supabase not configured, using fallback strategies")
            return self._get_fallback_strategies(context)
        
        # Determine distance category from target distance
        distance_category = self._get_distance_category(performance_analysis.target_distance)
        
        # Determine runner level
        runner_level = self._get_runner_level(performance_analysis)
        
        # Build situation description for embedding generation
        situation_description = self._build_situation_description_for_kb(
            context, 
            performance_analysis
        )
        
        # Generate embedding for current situation (vector search)
        situation_embedding = await self._generate_embedding(situation_description)
        
        try:
            client = await self._get_client()
            
            if situation_embedding:
                # NEXT-GEN: Vector-based semantic search
                print(f"   🔍 Vector search: distance={distance_category}, level={runner_level}")
                
                response = await client.post(
                    f"{self.supabase_url}/rest/v1/rpc/semantic_search_strategies_kb",
                    headers={
                        "apikey": self.supabase_key,
                        "Authorization": f"Bearer {self.supabase_key}",
                        "Content-Type": "application/json"
                    },
                    json={
                        "p_situation_embedding": situation_embedding,
                        "p_distance": distance_category,
                        "p_runner_level": runner_level,
                        "p_strategy_type": None,  # Get both core and micro
                        "p_match_threshold": 0.65,  # 65% similarity threshold
                        "p_match_count": 15  # Get top 15 for LLM refinement
                    }
                )
                
                if response.status_code == 200:
                    kb_strategies = response.json()
                    
                    if kb_strategies:
                        print(f"   ✅ Vector search found {len(kb_strategies)} strategies (avg similarity: {sum(s.get('similarity', 0) for s in kb_strategies)/len(kb_strategies):.0%})")
                    else:
                        print(f"   ⚠️ No vector matches above threshold, falling back to KB query")
                        # Fallback to non-vector query
                        kb_strategies = await self._query_kb_fallback(
                            client, distance_category, runner_level, 15
                        )
                else:
                    print(f"   ⚠️ Vector search failed: {response.status_code}, using fallback")
                    kb_strategies = await self._query_kb_fallback(
                        client, distance_category, runner_level, 15
                    )
            else:
                # No embedding available, use fallback query
                print(f"   ⚠️ Embedding generation failed, using KB query fallback")
                kb_strategies = await self._query_kb_fallback(
                    client, distance_category, runner_level, 15
                )
            
            if not kb_strategies:
                print(f"   ⚠️ No KB strategies found for {distance_category}")
                return self._get_fallback_strategies(context)
            
            # LLM refinement: Match conditions_to_use and when_not_to_use
            matched_strategies = await self._llm_match_conditions(
                kb_strategies=kb_strategies,
                situation_description=situation_description,
                performance_analysis=performance_analysis
            )
            
            # Convert to CoachingStrategy objects
            strategies = [
                CoachingStrategy(
                    id=s["id"],
                    strategy_name=s["title"],
                    strategy_text=s["strategy_text"],
                    strategy_context=f"Use when: {s['conditions_to_use']}. Avoid when: {s['when_not_to_use']}",
                    tags=s.get("tags", []),
                    trigger_conditions={
                        "conditions_to_use": s["conditions_to_use"],
                        "when_not_to_use": s["when_not_to_use"]
                    },
                    times_used=s.get("times_used", 0),
                    success_rate=s.get("success_rate", 0.0),
                    avg_effectiveness_score=s.get("avg_effectiveness_score", 0.0),
                    similarity_score=s.get("match_score", s.get("similarity", 0.7)),  # LLM match or vector similarity
                    source="kb_vector" if situation_embedding else "kb"
                )
                for s in matched_strategies
            ]
            
            print(f"   ✅ Final: {len(strategies)} strategies after LLM refinement")
            return strategies
                
        except Exception as e:
            print(f"   ❌ KB strategy retrieval error: {e}")
            import traceback
            traceback.print_exc()
        
        return self._get_fallback_strategies(context)
    
    async def _query_kb_fallback(
        self,
        client: httpx.AsyncClient,
        distance_category: str,
        runner_level: str,
        limit: int
    ) -> List[Dict[str, Any]]:
        """Fallback KB query without vector search."""
        try:
            response = await client.post(
                f"{self.supabase_url}/rest/v1/rpc/query_coaching_strategies_kb",
                headers={
                    "apikey": self.supabase_key,
                    "Authorization": f"Bearer {self.supabase_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "p_distance": distance_category,
                    "p_runner_level": runner_level,
                    "p_strategy_type": None,
                    "p_situation_description": None,
                    "p_match_count": limit
                }
            )
            
            if response.status_code == 200:
                return response.json()
        except Exception as e:
            print(f"   ⚠️ Fallback query error: {e}")
        
        return []
    
    def _get_distance_category(self, target_distance_meters: float) -> str:
        """Map target distance to KB distance category."""
        target_km = target_distance_meters / 1000.0
        
        if target_km < 3.0:
            return "casual"
        elif target_km <= 5.5:
            return "5k"
        elif target_km <= 11.0:
            return "10k"
        elif target_km <= 22.0:
            return "half"
        else:
            return "full"
    
    def _get_runner_level(self, perf: PerformanceAnalysis) -> str:
        """
        Determine runner level from performance data.
        Defaults to 'intermediate' if not determinable.
        """
        # Could be enhanced with user profile data
        # For now, use heuristics based on pace consistency and HR management
        
        # If pace is very consistent and HR stable → advanced
        if (perf.pace_trend == PaceTrend.STABLE and 
            perf.hr_trend == HRTrend.STABLE and
            abs(perf.pace_deviation) < 3.0):
            return "advanced"
        
        # If pace is erratic and HR spiking → beginner
        if (perf.pace_trend == PaceTrend.ERRATIC or
            perf.hr_trend == HRTrend.SPIKING or
            abs(perf.pace_deviation) > 15.0):
            return "beginner"
        
        # Default to intermediate
        return "intermediate"
    
    def _build_situation_description_for_kb(
        self,
        context: SituationContext,
        perf: PerformanceAnalysis
    ) -> str:
        """Build detailed situation description for KB condition matching."""
        
        current_km = perf.current_distance / 1000.0
        target_km = perf.target_distance / 1000.0
        km_completed = f"{current_km:.1f}"
        
        # Build pace description
        pace_desc = f"Current pace: {perf.current_pace:.2f} min/km"
        if perf.target_pace > 0:
            pace_diff = perf.current_pace - perf.target_pace
            if pace_diff > 0.1:
                pace_desc += f" (slower by {pace_diff:.2f} min/km)"
            elif pace_diff < -0.1:
                pace_desc += f" (faster by {abs(pace_diff):.2f} min/km)"
            else:
                pace_desc += " (on target)"
        
        # Build HR description
        hr_desc = ""
        if perf.current_hr:
            hr_desc = f"HR: {perf.current_hr} BPM"
            if perf.current_zone:
                hr_desc += f", Zone {perf.current_zone}"
            if perf.hr_trend == HRTrend.RISING:
                hr_desc += " (rising)"
            elif perf.hr_trend == HRTrend.SPIKING:
                hr_desc += " (spiking)"
            elif perf.hr_trend == HRTrend.STABLE:
                hr_desc += " (stable)"
        
        # Build cadence description (if available)
        cadence_desc = ""
        if perf.completed_intervals >= 2:
            # Estimate cadence trend from pace trend
            if perf.pace_trend == PaceTrend.DECLINING:
                cadence_desc = "cadence dropping"
            elif perf.pace_trend == PaceTrend.STABLE:
                cadence_desc = "cadence stable"
        
        return f"""
        At km {km_completed} of {target_km:.1f}km target.
        {pace_desc}
        {hr_desc}
        {cadence_desc}
        Pace trend: {context.pace_trend.value}
        HR trend: {context.hr_trend.value}
        Fatigue: {context.fatigue_level.value}
        Target status: {context.target_status.value}
        {"Cardiac drift detected (pace down, HR up)." if context.cardiac_drift else ""}
        {"Zone too high (>25% Zone 4-5)." if context.zone_too_high else ""}
        {"Injury risk signals present." if context.injury_risk else ""}
        {"Form breakdown detected." if context.form_breakdown else ""}
        {"Runner has capacity to push." if context.push_possible else ""}
        """.strip()
    
    async def _llm_match_conditions(
        self,
        kb_strategies: List[Dict[str, Any]],
        situation_description: str,
        performance_analysis: PerformanceAnalysis
    ) -> List[Dict[str, Any]]:
        """
        Use LLM to match strategies' conditions_to_use and when_not_to_use
        with the current situation. Returns matched strategies with match scores.
        """
        
        if not self.openai_key or not kb_strategies:
            # No LLM available, return top strategies by success rate
            return sorted(
                kb_strategies,
                key=lambda s: (s.get("success_rate", 0.0), s.get("times_used", 0)),
                reverse=True
            )[:8]
        
        # Build prompt for LLM condition matching
        strategies_text = "\n".join([
            f"{i+1}. [{s['id']}] {s['title']}\n"
            f"   Use when: {s['conditions_to_use']}\n"
            f"   Avoid when: {s['when_not_to_use']}\n"
            f"   Strategy: {s['strategy_text']}\n"
            f"   Success rate: {s.get('success_rate', 0.0):.0%} ({s.get('times_used', 0)} uses)"
            for i, s in enumerate(kb_strategies[:15])  # Limit to 15 for prompt size
        ])
        
        prompt = f"""
CURRENT RUNNING SITUATION:
{situation_description}

AVAILABLE STRATEGIES FROM KNOWLEDGE BASE:
{strategies_text}

TASK:
For each strategy, determine if its "conditions_to_use" MATCH the current situation
AND if its "when_not_to_use" does NOT match.

Return JSON array with:
[
  {{
    "id": "strategy_id",
    "match": true/false,
    "match_score": 0.0-1.0,
    "reason": "brief explanation"
  }},
  ...
]

Prioritize strategies where:
1. conditions_to_use clearly matches current situation
2. when_not_to_use does NOT match current situation
3. Higher success_rate (self-learning)
4. More times_used (proven strategies)

Be strict: only match if conditions clearly apply.
"""
        
        try:
            client = await self._get_client()
            
            response = await client.post(
                "https://api.openai.com/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {self.openai_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": "gpt-4o-mini",
                    "messages": [
                        {
                            "role": "system",
                            "content": "You are a running coach strategy matcher. Match strategies to situations based on their conditions_to_use and when_not_to_use criteria. Return only valid JSON."
                        },
                        {
                            "role": "user",
                            "content": prompt
                        }
                    ],
                    "temperature": 0.2,
                    "max_tokens": 2000,
                    "response_format": {"type": "json_object"}
                }
            )
            
            if response.status_code == 200:
                result = response.json()
                content = result["choices"][0]["message"]["content"]
                
                # Parse JSON response
                try:
                    if "```json" in content:
                        content = content.split("```json")[1].split("```")[0]
                    elif "```" in content:
                        content = content.split("```")[1].split("```")[0]
                    
                    parsed = json.loads(content.strip())
                    
                    # Handle both array and object formats
                    matches = parsed.get("matches", [])
                    if not matches and isinstance(parsed, dict) and "matches" not in parsed:
                        # Try to parse as array directly
                        try:
                            matches = json.loads(content)
                            if not isinstance(matches, list):
                                matches = []
                        except:
                            matches = []
                    
                    # Create match lookup
                    match_lookup = {m["id"]: m for m in matches if m.get("match", False)}
                    
                    # Filter and score strategies
                    matched_strategies = []
                    for s in kb_strategies:
                        match_info = match_lookup.get(s["id"])
                        if match_info:
                            s["match_score"] = match_info.get("match_score", 0.7)
                            s["match_reason"] = match_info.get("reason", "")
                            matched_strategies.append(s)
                    
                    # Sort by match_score, then success_rate, then times_used
                    matched_strategies.sort(
                        key=lambda x: (
                            x.get("match_score", 0.0),
                            x.get("success_rate", 0.0),
                            x.get("times_used", 0)
                        ),
                        reverse=True
                    )
                    
                    print(f"   🎯 LLM matched {len(matched_strategies)} strategies from {len(kb_strategies)} candidates")
                    return matched_strategies[:8]  # Top 8 matches
                    
                except json.JSONDecodeError as e:
                    print(f"   ⚠️ LLM response parse error: {e}")
                    # Fallback: return top strategies by success rate
                    return sorted(
                        kb_strategies,
                        key=lambda s: (s.get("success_rate", 0.0), s.get("times_used", 0)),
                        reverse=True
                    )[:8]
                    
        except Exception as e:
            print(f"   ⚠️ LLM condition matching error: {e}")
        
        # Fallback: return top strategies by success rate
        return sorted(
            kb_strategies,
            key=lambda s: (s.get("success_rate", 0.0), s.get("times_used", 0)),
            reverse=True
        )[:8]
    
    def _get_fallback_strategies(
        self,
        context: SituationContext
    ) -> List[CoachingStrategy]:
        """Return hardcoded fallback strategies when database unavailable."""
        
        strategies = []
        
        if context.cardiac_drift:
            strategies.append(CoachingStrategy(
                id="fallback-1",
                strategy_name="Cardiac Drift Management",
                strategy_text="Classic drift pattern. Ease 15 sec/km for next 500m. Focus on efficiency, not speed.",
                tags=["cardiac_drift", "hr_rising", "pace_decline"],
                source="fallback"
            ))
        
        if context.pace_trend == PaceTrend.DECLINING:
            strategies.append(CoachingStrategy(
                id="fallback-2",
                strategy_name="Cadence Reset",
                strategy_text="Quick feet, light steps. Count to 180. Shorten stride, find your rhythm.",
                tags=["pace_decline", "form_breakdown"],
                source="fallback"
            ))
        
        if context.fatigue_level in [FatigueLevel.HIGH, FatigueLevel.SEVERE]:
            strategies.append(CoachingStrategy(
                id="fallback-3",
                strategy_name="Active Recovery",
                strategy_text="Next 500m: easy pace, Zone 2. Shake out arms, breathe deep. Recharge.",
                tags=["fatigue_high", "recovery_needed"],
                source="fallback"
            ))
        
        if context.injury_risk:
            strategies.append(CoachingStrategy(
                id="fallback-4",
                strategy_name="Injury Prevention",
                strategy_text="Warning signs detected. Ease pace immediately. Shorter strides, land softly.",
                tags=["injury_risk"],
                source="fallback"
            ))
        
        if not strategies:
            strategies.append(CoachingStrategy(
                id="fallback-default",
                strategy_name="Maintain Pace",
                strategy_text="Hold current pace. Stay in Zone 3. Steady breathing. You're doing well.",
                tags=["pace_stable"],
                source="fallback"
            ))
        
        return strategies
    
    def _build_situation_description(self, context: SituationContext) -> str:
        """Build text description of situation for embedding."""
        return f"""
        Running situation: pace is {context.pace_trend.value}, heart rate is {context.hr_trend.value},
        fatigue level is {context.fatigue_level.value}, target status is {context.target_status.value}.
        {"Cardiac drift detected." if context.cardiac_drift else ""}
        {"Zone too high (>25% in Zone 4-5)." if context.zone_too_high else ""}
        {"Injury risk signals present." if context.injury_risk else ""}
        {"Form breakdown detected." if context.form_breakdown else ""}
        {"Runner has capacity to push." if context.push_possible else ""}
        {"Active recovery needed." if context.recovery_needed else ""}
        Coach personality: {context.personality.value}, energy level: {context.energy_level.value}.
        """
    
    # ========================================================================
    # MEM0 COACHING MEMORIES
    # ========================================================================
    
    async def _fetch_mem0_coaching_memories(
        self,
        user_id: str,
        context: SituationContext
    ) -> List[Mem0CoachingMemory]:
        """Fetch relevant coaching memories from Mem0."""
        
        if not self.mem0_api_key:
            return []
        
        memories = []
        
        try:
            client = await self._get_client()
            
            # Search for coaching feedback memories
            queries = [
                "coaching strategies that worked well",
                f"{context.pace_trend.value} pace coaching",
                f"{context.fatigue_level.value} fatigue running advice",
                "what motivates this runner",
                "running form cues that helped"
            ]
            
            for query in queries[:3]:  # Limit to 3 queries for speed
                response = await client.post(
                    f"{self.mem0_base_url}/memories/search",
                    headers={
                        "Authorization": f"Bearer {self.mem0_api_key}",
                        "Content-Type": "application/json"
                    },
                    json={
                        "query": query,
                        "user_id": user_id,
                        "limit": 3
                    }
                )
                
                if response.status_code == 200:
                    results = response.json().get("results", [])
                    for r in results:
                        memory = Mem0CoachingMemory(
                            memory_id=r.get("id", ""),
                            memory_text=r.get("memory", ""),
                            category=r.get("metadata", {}).get("category", "general"),
                            relevance_score=r.get("score", 0.0),
                            metadata=r.get("metadata", {})
                        )
                        
                        # Extract insights
                        text = memory.memory_text.lower()
                        if "worked" in text or "effective" in text or "helped" in text:
                            memory.what_worked = memory.memory_text
                        if "didn't work" in text or "ineffective" in text or "failed" in text:
                            memory.what_didnt_work = memory.memory_text
                        if "prefers" in text or "likes" in text or "responds to" in text:
                            memory.runner_preference = memory.memory_text
                        
                        memories.append(memory)
                        
        except Exception as e:
            print(f"   ⚠️ Mem0 fetch error: {e}")
        
        # Deduplicate and sort by relevance
        seen = set()
        unique_memories = []
        for m in sorted(memories, key=lambda x: x.relevance_score, reverse=True):
            if m.memory_text not in seen:
                seen.add(m.memory_text)
                unique_memories.append(m)
        
        return unique_memories[:5]  # Top 5 memories
    
    # ========================================================================
    # USER TOP STRATEGIES (Self-Learning)
    # ========================================================================
    
    async def _get_user_top_strategies(
        self,
        user_id: str
    ) -> List[Dict[str, Any]]:
        """Get strategies that have worked best for this user."""
        
        if not self.supabase_url or not self.supabase_key:
            return []
        
        try:
            client = await self._get_client()
            
            response = await client.post(
                f"{self.supabase_url}/rest/v1/rpc/get_user_top_strategies",
                headers={
                    "apikey": self.supabase_key,
                    "Authorization": f"Bearer {self.supabase_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "p_user_id": user_id,
                    "p_limit": 5
                }
            )
            
            if response.status_code == 200:
                return response.json()
                
        except Exception as e:
            print(f"   ⚠️ User top strategies error: {e}")
        
        return []
    
    # ========================================================================
    # STRATEGY SELECTION & ADAPTATION (LLM-Powered)
    # ========================================================================
    
    async def _select_and_adapt_strategy(
        self,
        context: SituationContext,
        strategies: List[CoachingStrategy],
        mem0_memories: List[Mem0CoachingMemory],
        user_top_strategies: List[Dict[str, Any]],
        performance_analysis: PerformanceAnalysis
    ) -> AdaptiveStrategyOutput:
        """Select best strategy and adapt it using LLM."""
        
        if not self.openai_key:
            # No LLM available, use best matching strategy directly
            return self._select_best_strategy_simple(context, strategies, mem0_memories)
        
        # Build LLM prompt for strategy selection and adaptation
        prompt = self._build_strategy_selection_prompt(
            context=context,
            strategies=strategies,
            mem0_memories=mem0_memories,
            user_top_strategies=user_top_strategies,
            performance_analysis=performance_analysis
        )
        
        try:
            client = await self._get_client()
            
            response = await client.post(
                "https://api.openai.com/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {self.openai_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": "gpt-4o-mini",
                    "messages": [
                        {
                            "role": "system",
                            "content": """You are an elite running coach strategy selector.
                            
Your task is to select and adapt the BEST coaching strategy for the current situation.
Output must be SHORT and ACTIONABLE (max 40 words).

PRIORITIZE:
1. Safety first (injury risk)
2. Immediate impact (what helps NOW)
3. Personalization (what works for THIS runner)
4. Self-learning (strategies with high success rates)

OUTPUT FORMAT (JSON):
{
    "strategy_text": "The adapted coaching strategy (max 40 words)",
    "strategy_name": "Name of strategy type",
    "situation_summary": "Brief situation description (10 words)",
    "selection_reason": "Why this strategy (15 words)",
    "confidence_score": 0.0-1.0,
    "expected_outcome": "What we expect if strategy works"
}"""
                        },
                        {
                            "role": "user",
                            "content": prompt
                        }
                    ],
                    "temperature": 0.3,
                    "max_tokens": 300
                }
            )
            
            if response.status_code == 200:
                result = response.json()
                content = result["choices"][0]["message"]["content"]
                
                # Parse JSON response
                try:
                    # Handle potential markdown code blocks
                    if "```json" in content:
                        content = content.split("```json")[1].split("```")[0]
                    elif "```" in content:
                        content = content.split("```")[1].split("```")[0]
                    
                    parsed = json.loads(content.strip())
                    
                    return AdaptiveStrategyOutput(
                        strategy_text=parsed.get("strategy_text", "Maintain current effort."),
                        strategy_name=parsed.get("strategy_name", "Adaptive Strategy"),
                        situation_summary=parsed.get("situation_summary", "Running situation assessed"),
                        selection_reason=parsed.get("selection_reason", "Best match for current state"),
                        source_strategies=strategies[:3],
                        mem0_insights_used=[m.memory_text for m in mem0_memories[:3]],
                        confidence_score=parsed.get("confidence_score", 0.7),
                        priority_tags=context.situation_tags[:3],
                        expected_outcome=parsed.get("expected_outcome", "Improved performance")
                    )
                    
                except json.JSONDecodeError:
                    # If JSON parsing fails, extract text directly
                    return AdaptiveStrategyOutput(
                        strategy_text=content[:200],
                        strategy_name="Adaptive Strategy",
                        situation_summary=f"{context.pace_trend.value} pace, {context.fatigue_level.value} fatigue",
                        selection_reason="LLM-generated response",
                        source_strategies=strategies[:3],
                        mem0_insights_used=[m.memory_text for m in mem0_memories[:3]],
                        confidence_score=0.6,
                        priority_tags=context.situation_tags[:3]
                    )
                    
        except Exception as e:
            print(f"   ❌ LLM strategy selection error: {e}")
        
        # Fallback to simple selection
        return self._select_best_strategy_simple(context, strategies, mem0_memories)
    
    def _build_strategy_selection_prompt(
        self,
        context: SituationContext,
        strategies: List[CoachingStrategy],
        mem0_memories: List[Mem0CoachingMemory],
        user_top_strategies: List[Dict[str, Any]],
        performance_analysis: PerformanceAnalysis
    ) -> str:
        """Build the LLM prompt for strategy selection."""
        
        # Format strategies
        strategies_text = "\n".join([
            f"- [{s.strategy_name}] (success: {s.success_rate:.0%}, used: {s.times_used}x, sim: {s.similarity_score:.0%}): {s.strategy_text}"
            for s in strategies[:6]
        ])
        
        # Format Mem0 memories
        memories_text = "\n".join([
            f"- {m.memory_text}"
            for m in mem0_memories[:5]
        ]) if mem0_memories else "No personalization data yet."
        
        # Format user's top strategies
        user_top_text = "\n".join([
            f"- {s.get('strategy_name', 'Unknown')} (user success: {s.get('user_success_rate', 0):.0%})"
            for s in user_top_strategies[:3]
        ]) if user_top_strategies else "No user history yet."
        
        # Performance context
        perf_context = f"""
Current pace: {performance_analysis.current_pace:.2f} min/km (target: {performance_analysis.target_pace:.2f})
HR: {performance_analysis.current_hr or 'N/A'} BPM, Zone: {performance_analysis.current_zone or 'N/A'}
Distance: {performance_analysis.current_distance/1000:.2f}km of {performance_analysis.target_distance/1000:.1f}km
Pace deviation: {performance_analysis.pace_deviation:+.1f}%
"""
        
        return f"""
SITUATION ANALYSIS:
- Pace trend: {context.pace_trend.value}
- HR trend: {context.hr_trend.value}
- Fatigue: {context.fatigue_level.value}
- Target status: {context.target_status.value}
- Cardiac drift: {"YES" if context.cardiac_drift else "No"}
- Zone too high: {"YES" if context.zone_too_high else "No"}
- Injury risk: {"YES" if context.injury_risk else "No"}
- Form breakdown: {"YES" if context.form_breakdown else "No"}
- Can push: {"Yes" if context.push_possible else "No"}
- Recovery needed: {"YES" if context.recovery_needed else "No"}

COACH SETTINGS:
- Personality: {context.personality.value.upper()}
- Energy: {context.energy_level.value.upper()}

PERFORMANCE DATA:
{perf_context}

AVAILABLE STRATEGIES (from RAG):
{strategies_text or "No matching strategies found."}

USER'S TOP STRATEGIES (self-learning):
{user_top_text}

MEM0 PERSONALIZATION (what works for this runner):
{memories_text}

TASK:
Select the BEST strategy for this EXACT situation and adapt it.
Combine insights from strategies, user history, and personalization.
Output must be SHORT (max 40 words), SPECIFIC, and ACTIONABLE.

If injury risk or recovery needed, prioritize safety.
If user has successful strategies, prefer those.
Match the coach personality ({context.personality.value}) and energy ({context.energy_level.value}).

OUTPUT JSON:
"""
    
    def _select_best_strategy_simple(
        self,
        context: SituationContext,
        strategies: List[CoachingStrategy],
        mem0_memories: List[Mem0CoachingMemory]
    ) -> AdaptiveStrategyOutput:
        """Simple strategy selection without LLM (fallback)."""
        
        if not strategies:
            return AdaptiveStrategyOutput(
                strategy_text="Maintain current pace. Stay focused. You're doing well.",
                strategy_name="Default Strategy",
                situation_summary=f"{context.pace_trend.value} pace, {context.fatigue_level.value} fatigue",
                selection_reason="No matching strategies found",
                confidence_score=0.5,
                priority_tags=context.situation_tags[:3]
            )
        
        # Score strategies based on match
        best_strategy = max(strategies, key=lambda s: (
            s.success_rate * 0.4 +
            s.similarity_score * 0.3 +
            len(set(s.tags) & set(context.situation_tags)) * 0.1 +
            (0.2 if s.source == "database" else 0.1)
        ))
        
        return AdaptiveStrategyOutput(
            strategy_text=best_strategy.strategy_text,
            strategy_name=best_strategy.strategy_name,
            situation_summary=f"{context.pace_trend.value} pace, {context.fatigue_level.value} fatigue",
            selection_reason=f"Best match: {best_strategy.success_rate:.0%} success rate",
            source_strategies=[best_strategy],
            mem0_insights_used=[m.memory_text for m in mem0_memories[:2]],
            confidence_score=0.6,
            priority_tags=context.situation_tags[:3]
        )
    
    # ========================================================================
    # EMBEDDING GENERATION
    # ========================================================================
    
    async def _generate_embedding(self, text: str) -> Optional[List[float]]:
        """Generate embedding using OpenAI (uses Edge Function or env key)."""
        # This method is kept for compatibility but won't be used
        # since we now use Edge Function for strategy selection
        return None
    
    async def _generate_embedding_with_key(self, text: str, openai_key: str) -> Optional[List[float]]:
        """Generate embedding using OpenAI with provided key."""
        
        if not openai_key:
            return None
        
        try:
            client = await self._get_client()
            
            response = await client.post(
                "https://api.openai.com/v1/embeddings",
                headers={
                    "Authorization": f"Bearer {openai_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": "text-embedding-3-small",
                    "input": text
                }
            )
            
            if response.status_code == 200:
                result = response.json()
                return result["data"][0]["embedding"]
                
        except Exception as e:
            print(f"   ❌ Embedding error: {e}")
        
        return None
    
    # ========================================================================
    # EXECUTION RECORDING (Self-Learning)
    # ========================================================================
    
    async def _record_execution(
        self,
        user_id: str,
        run_id: Optional[str],
        strategy: AdaptiveStrategyOutput,
        context: SituationContext,
        performance_analysis: PerformanceAnalysis
    ):
        """Record strategy execution for self-learning."""
        
        if not self.supabase_url or not self.supabase_key:
            return
        
        try:
            client = await self._get_client()
            
            # Get strategy_id from source strategies
            strategy_id = None
            if strategy.source_strategies:
                strategy_id = strategy.source_strategies[0].id
                if strategy_id.startswith("fallback"):
                    strategy_id = None
            
            execution_context = {
                "pace": performance_analysis.current_pace,
                "hr": performance_analysis.current_hr,
                "zone": performance_analysis.current_zone,
                "fatigue": context.fatigue_level.value,
                "target_status": context.target_status.value,
                "pace_trend": context.pace_trend.value,
                "hr_trend": context.hr_trend.value,
                "situation_tags": context.situation_tags
            }
            
            response = await client.post(
                f"{self.supabase_url}/rest/v1/rpc/record_strategy_execution",
                headers={
                    "apikey": self.supabase_key,
                    "Authorization": f"Bearer {self.supabase_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "p_user_id": user_id,
                    "p_run_id": run_id,
                    "p_strategy_id": strategy_id,
                    "p_execution_context": execution_context,
                    "p_strategy_delivered": strategy.strategy_text
                }
            )
            
            if response.status_code == 200:
                execution_id = response.json()
                strategy.execution_id = execution_id
                self._pending_executions[execution_id] = StrategyExecution(
                    id=execution_id,
                    user_id=user_id,
                    run_id=run_id,
                    strategy_id=strategy_id,
                    execution_context=execution_context,
                    strategy_delivered=strategy.strategy_text,
                    executed_at=datetime.now()
                )
                print(f"   ✅ Execution recorded: {execution_id[:8]}")
                
        except Exception as e:
            print(f"   ⚠️ Execution recording error: {e}")
    
    async def record_strategy_outcome(
        self,
        execution_id: str,
        outcome_metrics: Dict[str, Any],
        was_effective: bool,
        effectiveness_score: Optional[float] = None,
        effectiveness_reason: Optional[str] = None
    ) -> bool:
        """
        Record the outcome of a strategy execution (for self-learning).
        
        Call this after an interval to assess if the strategy worked.
        
        Args:
            execution_id: The execution ID from strategy delivery
            outcome_metrics: Metrics after strategy (e.g., pace_change, hr_change)
            was_effective: Did the strategy help?
            effectiveness_score: 0.0-1.0 score
            effectiveness_reason: Why it was/wasn't effective
            
        Returns:
            True if recorded successfully
        """
        
        if not self.supabase_url or not self.supabase_key:
            return False
        
        try:
            client = await self._get_client()
            
            response = await client.post(
                f"{self.supabase_url}/rest/v1/rpc/record_strategy_outcome",
                headers={
                    "apikey": self.supabase_key,
                    "Authorization": f"Bearer {self.supabase_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "p_execution_id": execution_id,
                    "p_outcome_metrics": outcome_metrics,
                    "p_was_effective": was_effective,
                    "p_effectiveness_score": effectiveness_score,
                    "p_effectiveness_reason": effectiveness_reason
                }
            )
            
            if response.status_code == 200:
                print(f"   ✅ Outcome recorded for {execution_id[:8]}: {'effective' if was_effective else 'ineffective'}")
                
                # Remove from pending
                if execution_id in self._pending_executions:
                    del self._pending_executions[execution_id]
                
                return True
                
        except Exception as e:
            print(f"   ❌ Outcome recording error: {e}")
        
        return False
    
    # ========================================================================
    # STRATEGY MONITORING
    # ========================================================================
    
    async def assess_strategy_effectiveness(
        self,
        execution_id: str,
        before_metrics: Dict[str, Any],
        after_metrics: Dict[str, Any]
    ) -> Tuple[bool, float, str]:
        """
        Automatically assess if a strategy was effective based on metrics.
        
        Args:
            execution_id: The execution to assess
            before_metrics: Metrics before strategy (pace, hr, zone, etc.)
            after_metrics: Metrics after strategy
            
        Returns:
            (was_effective, effectiveness_score, reason)
        """
        
        was_effective = False
        score = 0.5
        reasons = []
        
        # Get the execution context
        execution = self._pending_executions.get(execution_id)
        if not execution:
            return False, 0.0, "Execution not found"
        
        context = execution.execution_context
        
        # Pace improvement
        pace_before = before_metrics.get("pace", 0)
        pace_after = after_metrics.get("pace", 0)
        if pace_before > 0 and pace_after > 0:
            pace_change = pace_after - pace_before
            
            # If target was "behind", improvement is good
            if context.get("target_status") in ["slightly_behind", "way_behind"]:
                if pace_change < -0.05:  # Got faster
                    score += 0.3
                    reasons.append("Pace improved")
                    was_effective = True
            # If recovery was needed, slight slowdown is okay
            elif context.get("fatigue") in ["high", "severe"]:
                if abs(pace_change) < 0.1:  # Stabilized
                    score += 0.2
                    reasons.append("Pace stabilized during recovery")
                    was_effective = True
        
        # HR stabilization
        hr_before = before_metrics.get("hr", 0)
        hr_after = after_metrics.get("hr", 0)
        if hr_before > 0 and hr_after > 0:
            hr_change = hr_after - hr_before
            
            # If HR was rising/spiking, stabilization is good
            if context.get("hr_trend") in ["rising", "spiking"]:
                if hr_change < 3:  # Stabilized or dropped
                    score += 0.2
                    reasons.append("HR stabilized")
                    was_effective = True
        
        # Zone optimization
        zone_before = before_metrics.get("zone", 0)
        zone_after = after_metrics.get("zone", 0)
        if context.get("zone_too_high", False):
            if zone_after < zone_before:
                score += 0.2
                reasons.append("Moved to lower zone")
                was_effective = True
        
        # Cap score
        score = min(1.0, max(0.0, score))
        
        reason = "; ".join(reasons) if reasons else "No significant improvement detected"
        
        # Record the outcome
        await self.record_strategy_outcome(
            execution_id=execution_id,
            outcome_metrics={
                "pace_change": pace_after - pace_before if pace_before and pace_after else None,
                "hr_change": hr_after - hr_before if hr_before and hr_after else None,
                "zone_change": zone_after - zone_before if zone_before and zone_after else None
            },
            was_effective=was_effective,
            effectiveness_score=score,
            effectiveness_reason=reason
        )
        
        return was_effective, score, reason


