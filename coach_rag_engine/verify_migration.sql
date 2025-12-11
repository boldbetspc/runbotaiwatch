-- Quick verification queries for Coach RAG KB migration
-- Run these in Supabase SQL Editor to verify migration

-- 1. Check table exists and has 50 strategies
SELECT 
    COUNT(*) as total_strategies,
    COUNT(DISTINCT distance) as distance_categories,
    COUNT(CASE WHEN strategy_embedding IS NOT NULL THEN 1 END) as strategies_with_embeddings
FROM coaching_strategies_kb;

-- 2. Check strategies by distance
SELECT 
    distance,
    COUNT(*) as count,
    COUNT(CASE WHEN type = 'core' THEN 1 END) as core_strategies,
    COUNT(CASE WHEN type = 'micro' THEN 1 END) as micro_strategies
FROM coaching_strategies_kb
GROUP BY distance
ORDER BY 
    CASE distance
        WHEN 'casual' THEN 1
        WHEN '5k' THEN 2
        WHEN '10k' THEN 3
        WHEN 'half' THEN 4
        WHEN 'full' THEN 5
    END;

-- 3. Check functions exist
SELECT 
    routine_name,
    routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
    AND routine_name IN (
        'semantic_search_strategies_kb',
        'query_coaching_strategies_kb',
        'record_strategy_execution_kb',
        'record_strategy_outcome_kb',
        'get_user_top_strategies_kb',
        'update_strategy_embedding_kb'
    )
ORDER BY routine_name;

-- 4. Sample strategies (first 5)
SELECT 
    id,
    title,
    distance,
    type,
    runner_level,
    LEFT(strategy_text, 50) || '...' as strategy_preview,
    CASE WHEN strategy_embedding IS NULL THEN '❌ No embedding' ELSE '✅ Has embedding' END as embedding_status
FROM coaching_strategies_kb
ORDER BY distance, id
LIMIT 5;


