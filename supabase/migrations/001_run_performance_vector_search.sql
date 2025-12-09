-- ============================================================================
-- RAG-Driven Performance Analysis: Vector Search Function for Supabase
-- ============================================================================
-- 
-- This SQL migration creates the necessary infrastructure for RAG-based
-- AI coaching in the Runbot Watch app. It enables semantic search over
-- past running performance data using pgvector.
--
-- Prerequisites:
-- 1. Enable pgvector extension in Supabase dashboard
-- 2. Create run_performance table with vector column
--
-- Usage:
-- Run this migration via Supabase SQL editor or CLI:
--   supabase db push
--
-- ============================================================================

-- Enable pgvector extension (if not already enabled)
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================================
-- Table: run_performance (with vector embeddings)
-- ============================================================================
-- This table stores ONLY vector embeddings and derived analysis for RAG search.
-- All actual run data comes from run_activities and run_hr tables via run_id.
-- This avoids data duplication and maintains single source of truth.

CREATE TABLE IF NOT EXISTS run_performance (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    run_id UUID NOT NULL REFERENCES run_activities(id) ON DELETE CASCADE,
    
    -- Vector embedding (OpenAI text-embedding-3-small has 1536 dimensions)
    -- This is the ONLY unique data - everything else comes from existing tables
    run_embedding vector(1536),
    
    -- Optional: Derived analysis fields (not stored elsewhere)
    -- These are computed insights that enhance RAG search
    pace_trend TEXT, -- 'improving', 'stable', 'declining', 'erratic'
    fatigue_level TEXT, -- 'fresh', 'moderate', 'high', 'critical'
    performance_summary TEXT, -- AI-generated summary for context
    key_insights TEXT, -- Key takeaways for similar run matching
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for vector similarity search (IVFFlat for fast approximate search)
CREATE INDEX IF NOT EXISTS run_performance_embedding_idx 
ON run_performance 
USING ivfflat (run_embedding vector_cosine_ops)
WITH (lists = 100);

-- Index for user filtering
CREATE INDEX IF NOT EXISTS run_performance_user_id_idx 
ON run_performance(user_id);

-- ============================================================================
-- Function: match_run_performance
-- ============================================================================
-- Semantic search function using cosine similarity
-- Returns similar past runs based on embedding similarity
-- Joins with run_activities to get actual run data (no duplication!)

CREATE OR REPLACE FUNCTION match_run_performance(
    query_embedding vector(1536),
    match_threshold FLOAT DEFAULT 0.7,
    match_count INT DEFAULT 5,
    filter_user_id UUID DEFAULT NULL
)
RETURNS TABLE (
    run_id UUID,
    distance DOUBLE PRECISION,
    pace DOUBLE PRECISION,
    duration DOUBLE PRECISION,
    similarity FLOAT,
    performance_summary TEXT,
    key_insights TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        rp.run_id,
        ra.distance_meters AS distance, -- From run_activities
        ra.average_pace_minutes_per_km AS pace, -- From run_activities
        ra.duration_s::DOUBLE PRECISION AS duration, -- From run_activities
        1 - (rp.run_embedding <=> query_embedding) AS similarity,
        rp.performance_summary,
        rp.key_insights
    FROM run_performance rp
    INNER JOIN run_activities ra ON ra.id = rp.run_id
    WHERE 
        (filter_user_id IS NULL OR rp.user_id = filter_user_id)
        AND 1 - (rp.run_embedding <=> query_embedding) > match_threshold
    ORDER BY rp.run_embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- Function: store_run_performance_embedding
-- ============================================================================
-- Helper function to store ONLY embedding and derived analysis
-- Run data (distance, pace, HR, zones) should already be in run_activities/run_hr

-- Drop old version(s) if they exist (in case signature changed from previous migration)
-- This handles the case where an old version with different parameters exists
DO $$ 
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc 
              WHERE proname = 'store_run_performance_embedding') 
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.proname || '(' || r.args || ') CASCADE';
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION store_run_performance_embedding(
    p_user_id UUID,
    p_run_id UUID, -- Must reference existing run in run_activities
    p_embedding vector(1536) DEFAULT NULL,
    p_pace_trend TEXT DEFAULT NULL,
    p_fatigue_level TEXT DEFAULT NULL,
    p_performance_summary TEXT DEFAULT NULL,
    p_key_insights TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    result_id UUID;
BEGIN
    -- Upsert: Update if exists, insert if not
    INSERT INTO run_performance (
        user_id,
        run_id,
        run_embedding,
        pace_trend,
        fatigue_level,
        performance_summary,
        key_insights
    )
    VALUES (
        p_user_id,
        p_run_id,
        p_embedding,
        p_pace_trend,
        p_fatigue_level,
        p_performance_summary,
        p_key_insights
    )
    ON CONFLICT (run_id) DO UPDATE SET
        run_embedding = EXCLUDED.run_embedding,
        pace_trend = EXCLUDED.pace_trend,
        fatigue_level = EXCLUDED.fatigue_level,
        performance_summary = EXCLUDED.performance_summary,
        key_insights = EXCLUDED.key_insights,
        updated_at = NOW()
    RETURNING id INTO result_id;
    
    RETURN result_id;
END;
$$;

-- Add unique constraint on run_id (one embedding per run)
-- Using CREATE UNIQUE INDEX instead of ADD CONSTRAINT (PostgreSQL doesn't support IF NOT EXISTS for constraints)
CREATE UNIQUE INDEX IF NOT EXISTS run_performance_run_id_unique ON run_performance(run_id);

-- ============================================================================
-- Row Level Security (RLS)
-- ============================================================================

ALTER TABLE run_performance ENABLE ROW LEVEL SECURITY;

-- Users can only see their own performance data
CREATE POLICY "Users can view own run_performance"
    ON run_performance FOR SELECT
    USING (auth.uid() = user_id);

-- Users can insert their own performance data
CREATE POLICY "Users can insert own run_performance"
    ON run_performance FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Users can update their own performance data
CREATE POLICY "Users can update own run_performance"
    ON run_performance FOR UPDATE
    USING (auth.uid() = user_id);

-- Grant execute permissions on functions
GRANT EXECUTE ON FUNCTION match_run_performance TO authenticated;
GRANT EXECUTE ON FUNCTION store_run_performance_embedding TO authenticated;

-- ============================================================================
-- Comments for documentation
-- ============================================================================

COMMENT ON TABLE run_performance IS 'Stores ONLY vector embeddings and derived analysis. Run data comes from run_activities/run_hr via run_id (normalized design, no duplication)';
COMMENT ON FUNCTION match_run_performance IS 'Semantic search for similar past runs using cosine similarity. Joins with run_activities to get actual run data.';
COMMENT ON FUNCTION store_run_performance_embedding IS 'Stores embedding and derived analysis only. Run data must already exist in run_activities/run_hr.';

