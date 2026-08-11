# Sample Queries

Test your MongoDB Vector Search Agent with these queries.

## Semantic/Vector Search Queries
These queries require the agent to generate embeddings and perform vector search:

1. **Themes of Hope**
   - "Find movies about hope and redemption"
   - "Movies with themes of perseverance"

2. **Emotional Themes**
   - "Films about loss and grief"
   - "Movies exploring loneliness and isolation"
   - "Stories about overcoming adversity"

3. **Conceptual Searches**
   - "Movies about the meaning of life"
   - "Films exploring human nature"
   - "Stories about family legacy and inheritance"

4. **Abstract Concepts**
   - "Movies about time and its passage"
   - "Films dealing with identity crisis"
   - "Stories about second chances"

## Direct Query Examples
These queries filter by specific fields:

1. **By Year**
   - "Show me movies from 1994"
   - "Find films released in the 1980s"
   - "Movies from 2020"

2. **By Cast**
   - "Movies starring Tom Hanks"
   - "Films with Morgan Freeman"
   - "Movies featuring Leonardo DiCaprio"

3. **By Genre**
   - "List all comedy movies"
   - "Show me action films"
   - "Find documentaries"

4. **By Rating**
   - "Movies rated PG-13"
   - "R-rated films"
   - "Family-friendly movies (rated G or PG)"

5. **By Runtime**
   - "Movies longer than 3 hours"
   - "Short films under 90 minutes"

## Aggregation Queries
These queries involve sorting, grouping, or statistics:

1. **Top Rated**
   - "What are the top 10 highest rated movies?"
   - "Best sci-fi movies by rating"
   - "Top 5 action movies"

2. **Statistics**
   - "How many movies are in each genre?"
   - "Average runtime of action movies"
   - "Count of movies per year"

3. **Combined Filters**
   - "Top rated comedies from the 1990s"
   - "Best movies with Tom Hanks"
   - "Highest rated movies under 2 hours"

## Complex/Multi-step Queries
These may require multiple tool calls:

1. "Find movies similar to themes in The Shawshank Redemption"
2. "What highly-rated movies are about time travel?"
3. "Find recent movies (2015+) about family relationships"

## Expected Behavior

| Query Type | Tools Used | Collection |
|------------|------------|------------|
| Semantic (themes) | VectorSearch (`semantic_search`) | embedded_movies |
| Direct (filters) | MongoDB only | movies |
| Aggregations | MongoDB only | movies |
| Hybrid | VectorSearch + MongoDB | embedded_movies |
