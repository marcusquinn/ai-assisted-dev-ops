---
description: "YouTube channel intelligence - competitor profiling, outlier detection, content DNA analysis"
mode: subagent
model: standard
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# YouTube Channel Intelligence

## Quick Reference

```bash
youtube-helper.sh channel @handle          # Channel overview
youtube-helper.sh videos @handle 200       # Full video list with stats
youtube-helper.sh competitors @c1 @c2 @c3  # Side-by-side comparison
youtube-helper.sh transcript VIDEO_ID      # Transcript of a video
youtube-helper.sh quota                    # Check quota before heavy ops
```

## Channel Profiling Workflow

1. **Channel data** — `youtube-helper.sh channel @handle json`. Extract: subscriber count, total views, video count, creation date, upload frequency (total videos / channel age).

2. **Video enumeration** — `youtube-helper.sh videos @handle 200 json`.
   Calculate average/median views, upload frequency, duration distribution, and
   performance by publication cohort, normalized for video age where possible.
   Do not label one current view-count snapshot a trend.

3. **Outlier detection** — threshold: **3x channel median views**.

```bash
youtube-helper.sh videos @handle 200 json | node -e "
process.stdin.on('data', d => {
    const videos = JSON.parse(d);
    const views = videos.map(v => Number(v.statistics?.viewCount || 0)).sort((a,b) => a-b);
    const median = views[Math.floor(views.length / 2)];
    const threshold = median * 3;

    console.log('Median views:', median.toLocaleString());
    console.log('Outlier threshold (3x):', threshold.toLocaleString());
    console.log('');

    const outliers = videos
        .filter(v => Number(v.statistics?.viewCount || 0) > threshold)
        .sort((a,b) => Number(b.statistics?.viewCount || 0) - Number(a.statistics?.viewCount || 0));

    console.log('Outlier videos (' + outliers.length + '):');
    outliers.forEach(v => {
        const views = Number(v.statistics?.viewCount || 0);
        const multiplier = (views / median).toFixed(1);
        console.log('  ' + multiplier + 'x | ' + views.toLocaleString() + ' views | ' + v.snippet?.title);
    });
});
"
```

4. **Content DNA** — analyze outliers for: topic clusters, title patterns (numbers/questions/how-to/brackets), duration sweet spot, thumbnail style (use `image-understanding.md`), hook patterns (transcripts of top 5, first 30 seconds).

```bash
for vid in VIDEO_ID_1 VIDEO_ID_2 VIDEO_ID_3; do
    echo "=== $vid ==="
    youtube-helper.sh transcript "$vid" | head -20
    echo ""
done
```

5. **Store findings** — `memory-helper.sh store --type WORKING_SOLUTION --namespace youtube "Channel profile @handle: [subs] subs, [views/vid] avg views, uploads [freq]. Content DNA: [topics], [formats]. Outlier pattern: [description]. Weakness: [gap identified]."`

## Competitor Comparison Matrix

| Metric | Your Channel | Competitor 1 | Competitor 2 | Competitor 3 |
|--------|-------------|-------------|-------------|-------------|
| Subscribers | | | | |
| Total views | | | | |
| Video count | | | | |
| Avg views/video | | | | |
| Views/subscriber | | | | |
| Upload frequency | | | | |
| Avg duration | | | | |
| Top topic | | | | |
| Outlier count (3x) | | | | |

```bash
youtube-helper.sh competitors @you @comp1 @comp2 @comp3
```

## Engagement Metrics

| Metric | Formula | Good Benchmark |
|--------|---------|----------------|
| Views/Subscriber | total_views / subscribers | > 5.0 |
| Avg Views/Video | total_views / video_count | Varies by niche |
| Like Rate | likes / views | > 3% |
| Comment Rate | comments / views | > 0.5% |
| Upload Consistency | std_dev of days between uploads | Lower = better |

## Quota Budget

| Operation | Cost | Typical Usage |
|-----------|------|---------------|
| Channel lookup (per channel) | 1 unit | 5 channels = 5 units |
| Video enumeration (per 50 videos) | 1 unit | 200 videos = 4 units |
| Video details (per 50 videos) | 1 unit | 200 videos = 4 units |
| Transcripts (via yt-dlp) | 0 units | Unlimited |
| **Full competitor analysis (5 channels)** | | **~50 units** |

Daily limit: 10,000 units.

## Output Format

```markdown
## Channel Profile: [Name] (@handle)

**Overview**: [subscribers] subscribers, [total_views] total views, [video_count] videos
**Created**: [date] | **Upload frequency**: [X videos/week]
**Niche**: [primary topic]

### Performance Metrics
- Average views/video: [X]
- Median views/video: [X]
- Views/subscriber ratio: [X]
- Like rate: [X]%

### Content DNA
- **Primary topics**: [topic1], [topic2], [topic3]
- **Dominant format**: [format description]
- **Duration sweet spot**: [X-Y minutes]
- **Title patterns**: [patterns observed]

### Outlier Videos ([count] found, threshold: [X] views)
1. [Title] - [views] views ([multiplier]x median)
2. [Title] - [views] views ([multiplier]x median)
3. [Title] - [views] views ([multiplier]x median)

### Strategic Insights
- **Strength**: [what they do well]
- **Weakness**: [content gap or missed opportunity]
- **Opportunity**: [what you could do differently]
```

## Related

- `youtube.md` - Main YouTube orchestrator (this directory)
- `topic-research.md` - Find content gaps from intel data
- `optimizer.md` - Apply outlier title/tag patterns
- `seo/keyword-research.md` - Deep keyword analysis
- `tools/data-extraction/outscraper.md` - YouTube comment extraction
