// Supabase Edge Function: OpenAI Proxy
// ====================================
// 
// Proxies requests to OpenAI API for:
// 1. Text-to-Speech (TTS) - endpoint: "audio/speech"
// 2. Chat Completions - endpoint: (default, messages array in body)
// 3. Embeddings - endpoint: "embeddings"
//
// Secrets are stored in Supabase Dashboard → Edge Functions → Secrets
// Required secret: OPENAI_API_KEY
//
// Usage: POST /functions/v1/openai-proxy
// Headers: 
//   - Authorization: Bearer <token>
//   - apikey: <anon_key>
//   - Content-Type: application/json
//
// Request body format:
//   For TTS: { "endpoint": "audio/speech", "input": "text", "model": "tts-1", "voice": "nova", ... }
//   For Embeddings: { "endpoint": "embeddings", "model": "text-embedding-3-small", "input": "text" }
//   For Chat: { "messages": [...], "model": "gpt-4o-mini", ... } (no endpoint field)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface TTSPayload {
  endpoint: "audio/speech"
  input: string
  model?: string
  voice?: string
  response_format?: string
  speed?: number
}

interface EmbeddingsPayload {
  endpoint: "embeddings"
  model: string
  input: string | string[]
}

interface ChatPayload {
  messages: any[]
  model: string
  temperature?: number
  max_tokens?: number
  [key: string]: any
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Get OpenAI API key from environment (set in Supabase Dashboard)
    const openaiKey = Deno.env.get("OPENAI_API_KEY")
    
    if (!openaiKey) {
      console.error("❌ OPENAI_API_KEY not configured in Edge Function secrets")
      return new Response(
        JSON.stringify({ error: "OPENAI_API_KEY not configured in Edge Function secrets" }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Parse request body
    const body = await req.json()
    const endpoint = body.endpoint

    console.log(`📥 [openai-proxy] Request received - endpoint: ${endpoint || 'chat/completions'}`)

    // Route 1: Text-to-Speech (TTS)
    if (endpoint === "audio/speech") {
      const ttsPayload = body as TTSPayload
      
      if (!ttsPayload.input) {
        return new Response(
          JSON.stringify({ error: "Missing 'input' field for TTS request" }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }

      console.log(`🎙️ [openai-proxy] TTS request - model: ${ttsPayload.model || 'tts-1-hd'}, input length: ${ttsPayload.input.length}`)

      // Call OpenAI TTS API
      const response = await fetch("https://api.openai.com/v1/audio/speech", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: ttsPayload.model || "tts-1-hd",
          input: ttsPayload.input,
          voice: ttsPayload.voice || "nova",
          response_format: ttsPayload.response_format || "mp3",
          speed: ttsPayload.speed || 1.0
        })
      })

      if (!response.ok) {
        const errorText = await response.text()
        console.error(`❌ [openai-proxy] TTS API error: ${response.status} - ${errorText}`)
        return new Response(
          JSON.stringify({ error: `TTS API error: ${errorText}` }),
          { 
            status: response.status, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }

      // TTS returns binary audio data
      const audioData = await response.arrayBuffer()
      console.log(`✅ [openai-proxy] TTS success - audio size: ${audioData.byteLength} bytes`)
      
      return new Response(audioData, {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'audio/mpeg',
        }
      })
    }

    // Route 2: Embeddings
    if (endpoint === "embeddings") {
      const embeddingsPayload = body as EmbeddingsPayload
      
      if (!embeddingsPayload.input) {
        return new Response(
          JSON.stringify({ error: "Missing 'input' field for embeddings request" }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }

      if (!embeddingsPayload.model) {
        return new Response(
          JSON.stringify({ error: "Missing 'model' field for embeddings request" }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }

      console.log(`🔍 [openai-proxy] Embeddings request - model: ${embeddingsPayload.model}, input type: ${typeof embeddingsPayload.input}`)

      // Call OpenAI Embeddings API
      const response = await fetch("https://api.openai.com/v1/embeddings", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: embeddingsPayload.model,
          input: embeddingsPayload.input
        })
      })

      if (!response.ok) {
        const errorText = await response.text()
        console.error(`❌ [openai-proxy] Embeddings API error: ${response.status} - ${errorText}`)
        return new Response(
          JSON.stringify({ error: `Embeddings API error: ${errorText}` }),
          { 
            status: response.status, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }

      const embeddingsData = await response.json()
      console.log(`✅ [openai-proxy] Embeddings success - dimensions: ${embeddingsData.data?.[0]?.embedding?.length || 'unknown'}`)
      
      return new Response(JSON.stringify(embeddingsData), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Route 3: Chat Completions (default - no endpoint field, or endpoint not recognized)
    const chatPayload = body as ChatPayload
    
    if (!chatPayload.messages) {
      return new Response(
        JSON.stringify({ 
          error: "Invalid request: messages array is required for chat completions, or endpoint=audio/speech for TTS, or endpoint=embeddings for embeddings"
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    console.log(`💬 [openai-proxy] Chat completion request - model: ${chatPayload.model || 'gpt-4o-mini'}, messages: ${chatPayload.messages.length}`)

    // Call OpenAI Chat Completions API
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: chatPayload.model || "gpt-4o-mini",
        messages: chatPayload.messages,
        temperature: chatPayload.temperature,
        max_tokens: chatPayload.max_tokens,
        // Include any other fields that might be in the payload
        ...Object.fromEntries(
          Object.entries(chatPayload).filter(([key]) => 
            !['endpoint', 'model', 'messages', 'temperature', 'max_tokens'].includes(key)
          )
        )
      })
    })

    if (!response.ok) {
      const errorText = await response.text()
      console.error(`❌ [openai-proxy] Chat API error: ${response.status} - ${errorText}`)
      return new Response(
        JSON.stringify({ error: `Chat API error: ${errorText}` }),
        { 
          status: response.status, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    const chatData = await response.json()
    console.log(`✅ [openai-proxy] Chat completion success`)
    
    return new Response(JSON.stringify(chatData), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })

  } catch (error) {
    console.error(`❌ [openai-proxy] Unexpected error:`, error)
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )
  }
})

