// Supabase Edge Function: Coach RAG Strategy
// ==========================================
// 
// Gets adaptive coaching strategy using secrets internally.
// Secrets are stored in Supabase Dashboard → Edge Functions → Secrets
// 
// This Edge Function:
// 1. Receives performance analysis + context
// 2. Uses OpenAI/Mem0 secrets internally (from env vars)
// 3. Calls OpenAI/Mem0 APIs directly
// 4. Returns final strategy (secrets never exposed)
//
// Usage: POST /functions/v1/coach-rag-strategy
// Headers: Authorization: Bearer <anon_key>

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface PerformanceAnalysis {
  current_pace: number
  target_pace: number
  current_distance: number
  target_distance: number
  elapsed_time: number
  current_hr?: number
  average_hr?: number
  max_hr?: number
  current_zone?: number
  zone_percentages: Record<number, number>
  pace_trend: string
  hr_trend: string
  fatigue_level: string
  target_status: string
  performance_summary: string
  heart_zone_analysis: string
  interval_trends: string
  hr_variation_analysis: string
  injury_risk_signals: string[]
  adaptive_microstrategy: string
  pace_deviation: number
  completed_intervals: number
  interval_paces: number[]
}

interface StrategyRequest {
  performance_analysis: PerformanceAnalysis
  personality: string  // 'strategist' | 'pacer' | 'finisher'
  energy_level: string  // 'low' | 'medium' | 'high'
  user_id: string
  run_id?: string
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Verify request is authenticated
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Parse request body
    const body: StrategyRequest = await req.json()
    const { performance_analysis, personality, energy_level, user_id, run_id } = body

    // Get secrets from environment (set in Supabase Dashboard)
    // Secrets are accessible to all Edge Functions
    // Use robust approach to find OPENAI_API_KEY (handle variations, trailing spaces, etc.)
    let OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')
    
    // If not found, try with trailing space (common issue)
    if (!OPENAI_API_KEY) {
      OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY ')
    }
    
    // If still not found, try accessing all environment variables and find the right one
    if (!OPENAI_API_KEY) {
      const allEnvVars = Object.keys(Deno.env.toObject())
      console.log('📋 Available environment variables:', allEnvVars)
      
      // Look for any key containing 'openai'
      const openaiKey = allEnvVars.find(key => 
        key.toLowerCase().includes('openai')
      )
      
      if (openaiKey) {
        console.log('🔑 Found OpenAI key:', openaiKey)
        OPENAI_API_KEY = Deno.env.get(openaiKey)
      }
    }
    
    const MEM0_API_KEY = Deno.env.get('MEM0_API_KEY')
    const MEM0_BASE_URL = Deno.env.get('MEM0_BASE_URL') || 'https://api.mem0.ai/v1'

    // Debug: Log available env vars (without exposing values)
    console.log('Environment check:', {
      hasOpenAIKey: !!OPENAI_API_KEY,
      hasMem0Key: !!MEM0_API_KEY,
      envKeys: Object.keys(Deno.env.toObject()).filter(k => k.includes('API') || k.includes('KEY'))
    })

    if (!OPENAI_API_KEY) {
      console.error('❌ OPENAI_API_KEY not found in environment variables')
      const allEnvVars = Object.keys(Deno.env.toObject())
      return new Response(
        JSON.stringify({ 
          error: 'OPENAI_API_KEY not configured in Edge Function secrets',
          hint: 'Check Supabase Dashboard → Edge Functions → Secrets. Secret name must be exactly: OPENAI_API_KEY',
          debug: 'Available env vars: ' + allEnvVars.join(', ')
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Initialize Supabase client (service role for RPC calls)
    const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 1. Determine distance category
    const targetKm = performance_analysis.target_distance / 1000.0
    let distanceCategory = 'casual'
    if (targetKm >= 3 && targetKm <= 5.5) distanceCategory = '5k'
    else if (targetKm <= 11) distanceCategory = '10k'
    else if (targetKm <= 22) distanceCategory = 'half'
    else if (targetKm > 22) distanceCategory = 'full'

    // 2. Determine runner level (heuristic)
    let runnerLevel = 'intermediate'
    if (performance_analysis.pace_trend === 'erratic' || 
        performance_analysis.hr_trend === 'spiking' ||
        Math.abs(performance_analysis.pace_deviation) > 15) {
      runnerLevel = 'beginner'
    } else if (performance_analysis.pace_trend === 'stable' && 
               performance_analysis.hr_trend === 'stable' &&
               Math.abs(performance_analysis.pace_deviation) < 3) {
      runnerLevel = 'advanced'
    }

    // 3. Query KB strategies from Supabase
    const { data: strategies, error: kbError } = await supabase.rpc('query_coaching_strategies_kb', {
      p_distance: distanceCategory,
      p_runner_level: runnerLevel,
      p_strategy_type: null,
      p_situation_description: null,
      p_match_count: 15
    })

    if (kbError) {
      console.error('KB query error:', kbError)
      return new Response(
        JSON.stringify({ error: 'Failed to query knowledge base', details: kbError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!strategies || strategies.length === 0) {
      return new Response(
        JSON.stringify({ error: 'No strategies found in knowledge base' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 4. Build situation description for LLM
    const currentKm = (performance_analysis.current_distance / 1000).toFixed(1)
    const targetKmStr = (performance_analysis.target_distance / 1000).toFixed(1)
    const paceDiff = performance_analysis.current_pace - performance_analysis.target_pace
    const paceDesc = paceDiff > 0.1 
      ? `${performance_analysis.current_pace.toFixed(2)} min/km (slower by ${paceDiff.toFixed(2)})`
      : paceDiff < -0.1
      ? `${performance_analysis.current_pace.toFixed(2)} min/km (faster by ${Math.abs(paceDiff).toFixed(2)})`
      : `${performance_analysis.current_pace.toFixed(2)} min/km (on target)`

    const situationDescription = `
      At km ${currentKm} of ${targetKmStr}km target.
      Current pace: ${paceDesc}.
      HR: ${performance_analysis.current_hr || 'N/A'} BPM, Zone: ${performance_analysis.current_zone || 'N/A'}.
      Pace trend: ${performance_analysis.pace_trend}, HR trend: ${performance_analysis.hr_trend}.
      Fatigue: ${performance_analysis.fatigue_level}, Target status: ${performance_analysis.target_status}.
      ${performance_analysis.performance_summary || ''}
    `.trim()

    // 5. Use OpenAI to match conditions and select strategy
    const strategiesText = strategies.slice(0, 10).map((s: any, i: number) =>
      `${i + 1}. [${s.id}] ${s.title}\n   Use when: ${s.conditions_to_use}\n   Avoid when: ${s.when_not_to_use}\n   Strategy: ${s.strategy_text}\n   Success: ${((s.success_rate || 0) * 100).toFixed(0)}% (${s.times_used || 0} uses)`
    ).join('\n\n')

    const llmPrompt = `
SITUATION:
${situationDescription}

AVAILABLE STRATEGIES FROM KNOWLEDGE BASE:
${strategiesText}

TASK:
Select the BEST strategy for this EXACT situation. 
- Match conditions_to_use with current situation
- Ensure when_not_to_use does NOT match
- Prioritize strategies with higher success rates
- Adapt strategy text to be concise (max 40 words)

Output JSON:
{
  "strategy_id": "strategy_id",
  "strategy_text": "adapted strategy text (max 40 words, actionable)",
  "strategy_name": "strategy name",
  "situation_summary": "brief situation (10 words)",
  "selection_reason": "why this strategy (15 words)",
  "confidence_score": 0.0-1.0,
  "expected_outcome": "what we expect if strategy works"
}
`

    // Call OpenAI API (secrets used internally)
    const openaiResponse = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: 'You are an elite running coach strategy selector. Match strategies to situations based on conditions_to_use and when_not_to_use. Output only valid JSON.'
          },
          {
            role: 'user',
            content: llmPrompt
          }
        ],
        temperature: 0.3,
        max_tokens: 300,
        response_format: { type: 'json_object' }
      })
    })

    if (!openaiResponse.ok) {
      const error = await openaiResponse.text()
      console.error('OpenAI API error:', error)
      // Fallback to top strategy by success rate
      const topStrategy = strategies[0]
      const fallbackResult = {
        strategy_id: topStrategy.id,
        strategy_text: topStrategy.strategy_text,
        strategy_name: topStrategy.title,
        situation_summary: `${performance_analysis.pace_trend} pace, ${performance_analysis.fatigue_level} fatigue`,
        selection_reason: 'Top success rate strategy (LLM unavailable)',
        confidence_score: topStrategy.success_rate || 0.7,
        expected_outcome: 'Improved performance'
      }
      
      // Record execution (fire and forget, don't wait for completion)
      supabase.rpc('record_strategy_execution_kb', {
        p_user_id: user_id,
        p_run_id: run_id || null,
        p_strategy_id: fallbackResult.strategy_id,
        p_execution_context: {
          pace: performance_analysis.current_pace,
          hr: performance_analysis.current_hr,
          zone: performance_analysis.current_zone,
          fatigue: performance_analysis.fatigue_level,
          target_status: performance_analysis.target_status,
          pace_trend: performance_analysis.pace_trend,
          hr_trend: performance_analysis.hr_trend
        },
        p_strategy_delivered: fallbackResult.strategy_text,
        p_strategy_title: fallbackResult.strategy_name,
        p_condition_match_score: fallbackResult.confidence_score
      }).then(({ error }) => {
        if (error) console.error('Execution recording error:', error)
      }, (err) => {
        console.error('Execution recording promise rejection:', err)
      })

      return new Response(
        JSON.stringify({
          success: true,
          strategy: fallbackResult
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        },
      )
    }

    const openaiResult = await openaiResponse.json()
    const llmContent = openaiResult.choices[0].message.content

    // Parse LLM response
    let strategyResult
    try {
      strategyResult = JSON.parse(llmContent)
      
      // Validate required fields
      if (!strategyResult.strategy_id || !strategyResult.strategy_text) {
        throw new Error('Invalid LLM response format')
      }
    } catch (e) {
      console.error('LLM parse error:', e)
      // Fallback: use top strategy by success rate
      const topStrategy = strategies[0]
      strategyResult = {
        strategy_id: topStrategy.id,
        strategy_text: topStrategy.strategy_text,
        strategy_name: topStrategy.title,
        situation_summary: `${performance_analysis.pace_trend} pace, ${performance_analysis.fatigue_level} fatigue`,
        selection_reason: 'Top success rate strategy (LLM parse failed)',
        confidence_score: topStrategy.success_rate || 0.7,
        expected_outcome: 'Improved performance'
      }
    }

    // 6. Record execution for self-learning (async, don't wait)
    supabase.rpc('record_strategy_execution_kb', {
      p_user_id: user_id,
      p_run_id: run_id || null,
      p_strategy_id: strategyResult.strategy_id,
      p_execution_context: {
        pace: performance_analysis.current_pace,
        hr: performance_analysis.current_hr,
        zone: performance_analysis.current_zone,
        fatigue: performance_analysis.fatigue_level,
        target_status: performance_analysis.target_status,
        pace_trend: performance_analysis.pace_trend,
        hr_trend: performance_analysis.hr_trend,
        distance: distanceCategory,
        runner_level: runnerLevel
      },
      p_strategy_delivered: strategyResult.strategy_text,
      p_strategy_title: strategyResult.strategy_name,
      p_condition_match_score: strategyResult.confidence_score
    }).then(({ error }) => {
      if (error) console.error('Execution recording error:', error)
    }, (err) => {
      console.error('Execution recording promise rejection:', err)
    })

    // 7. Return final strategy (secrets never exposed)
    return new Response(
      JSON.stringify({
        success: true,
        strategy: {
          strategy_text: strategyResult.strategy_text,
          strategy_name: strategyResult.strategy_name,
          situation_summary: strategyResult.situation_summary,
          selection_reason: strategyResult.selection_reason,
          confidence_score: strategyResult.confidence_score,
          expected_outcome: strategyResult.expected_outcome,
          strategy_id: strategyResult.strategy_id
        }
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      },
    )
  } catch (error) {
    console.error('Error in coach-rag-strategy:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      },
    )
  }
})

