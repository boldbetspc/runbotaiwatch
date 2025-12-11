"""
Initialize KB Embeddings
========================

Generates and stores vector embeddings for all strategies in the KB.
Run this after seeding the KB to enable vector-based semantic search.

Usage:
    python -m coach_rag_engine.initialize_kb_embeddings
"""

import asyncio
import os
import sys
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent))

from dotenv import load_dotenv
from engine import CoachRAGEngine


async def main():
    """Generate embeddings for all KB strategies."""
    
    print("=" * 60)
    print("COACH RAG KB - Embedding Initialization")
    print("=" * 60)
    
    # Load environment variables
    load_dotenv()
    
    # Initialize engine
    # Note: For embedding generation, we need OpenAI key locally
    # After embeddings are generated, Edge Function will handle secrets
    engine = CoachRAGEngine(
        supabase_url=os.getenv("SUPABASE_URL"),
        supabase_anon_key=os.getenv("SUPABASE_ANON_KEY")
    )
    
    # For embedding generation, we need OpenAI key temporarily
    # Set it as environment variable or pass directly
    if not os.getenv("OPENAI_API_KEY"):
        print("⚠️  OPENAI_API_KEY not found in environment")
        print("   Embedding generation requires OpenAI API key")
        print("   Set it temporarily: export OPENAI_API_KEY=sk-...")
        return
    
    try:
        # Generate embeddings for all strategies missing them
        count = await engine.generate_and_store_kb_embeddings()
        
        print("\n" + "=" * 60)
        print(f"✅ Initialization complete: {count} embeddings generated")
        print("=" * 60)
        
    finally:
        await engine.close()


if __name__ == "__main__":
    asyncio.run(main())

