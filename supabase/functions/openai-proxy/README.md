# OpenAI Proxy Edge Function

This Supabase Edge Function proxies requests to the OpenAI API for:
- **Text-to-Speech (TTS)** - Converts text to speech audio
- **Chat Completions** - GPT-4o-mini chat completions
- **Embeddings** - Text embeddings for RAG performance analysis

## Setup

1. **Set the OpenAI API Key Secret:**
   - Go to Supabase Dashboard → Edge Functions → Secrets
   - Add secret: `OPENAI_API_KEY` with your OpenAI API key

2. **Deploy the function:**
   ```bash
   supabase functions deploy openai-proxy
   ```

## Usage

### Text-to-Speech (TTS)

```json
POST /functions/v1/openai-proxy
{
  "endpoint": "audio/speech",
  "input": "Your text here",
  "model": "tts-1",  // optional, defaults to "tts-1-hd"
  "voice": "nova",   // optional, defaults to "nova"
  "response_format": "mp3",  // optional, defaults to "mp3"
  "speed": 1.0       // optional, defaults to 1.0
}
```

Returns: Binary MP3 audio data

### Embeddings

```json
POST /functions/v1/openai-proxy
{
  "endpoint": "embeddings",
  "model": "text-embedding-3-small",
  "input": "Text to embed"
}
```

Returns: OpenAI embeddings response with `data[0].embedding` array

### Chat Completions

```json
POST /functions/v1/openai-proxy
{
  "messages": [
    { "role": "system", "content": "You are a helpful assistant" },
    { "role": "user", "content": "Hello!" }
  ],
  "model": "gpt-4o-mini",
  "temperature": 0.7,
  "max_tokens": 150
}
```

Returns: OpenAI chat completion response

## Headers

All requests require:
- `Authorization: Bearer <token>` (user token or anon key)
- `apikey: <anon_key>` (Supabase anon key)
- `Content-Type: application/json`

## Error Handling

The function returns appropriate HTTP status codes:
- `200` - Success
- `400` - Bad request (missing required fields)
- `500` - Server error (API key not configured, OpenAI API error, etc.)

