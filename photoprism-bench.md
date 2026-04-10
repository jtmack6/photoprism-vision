# Vision Model Benchmarks

Benchmarking results for the photoprism-vision API across different hardware and models. Test dataset is COCO val2017 (5,000 images with ground-truth captions and object labels).

## Test Infrastructure

Benchmark script: `~/Projects/Photo/test-images/bench.py`

```bash
# Run 10 random images against all endpoints
python3 bench.py -n 10 -o results.json

# Test specific endpoints
python3 bench.py -n 20 --endpoints caption labels

# Compare Ollama captions vs kosmos-2
python3 bench.py -n 10 --endpoints caption caption-ollama -o compare.json

# Different random seed for different image selection
python3 bench.py -n 10 --seed 123
```

### Available Endpoints

| Endpoint | Model | Backend |
|---|---|---|
| `caption` | kosmos-2 | Local PyTorch (CPU) |
| `caption-ollama` | llama3.2-vision (Ollama) | GPU/CPU |
| `labels` | llama3.2-vision (Ollama) | GPU/CPU |
| `nsfw` | nsfw_image_detector | Local PyTorch (CPU) |

### Test Dataset

COCO val2017: 5,000 images with 5 human-written captions each + object labels.

```bash
# Download (~1.3GB total)
cd ~/Projects/Photo/test-images
curl -LO http://images.cocodataset.org/zips/val2017.zip
curl -LO http://images.cocodataset.org/annotations/annotations_trainval2017.zip
unzip val2017.zip
unzip annotations_trainval2017.zip
```

## AMD RX 7600 Results (2026-04-09)

Hardware: RX 7600 8GB, ROCm 7.1.1, Ollama ROCm, SDDM stopped, `ROCR_VISIBLE_DEVICES=0`
Ollama: 30/41 layers on GPU, 11 on CPU. `llama3.2-vision:latest` (11B, Q4).

### Timing Summary (n=10)

| Endpoint | Avg | Min | Max |
|---|---|---|---|
| Caption (kosmos-2, local) | 10.8s | 6.0s | 16.8s |
| Labels (llama3.2-vision, Ollama) | 11.4s | 6.3s | 24.5s |
| NSFW (nsfw_image_detector, local) | 1.2s | 0.5s | 7.0s |

### Caption Quality (kosmos-2)

| Image | Ground Truth | kosmos-2 Output | Verdict |
|---|---|---|---|
| Train w/ graffiti | "A passenger train that has some graffiti on it" | "A train and a person standing in front of it" | Partial — missed graffiti |
| British flag umbrella | "A black and white image with a colored british flag umbrella" | "A group of people walking down a street" | Missed — lost key detail |
| Teddy bear + photo | "A Beanie Baby beside a vintage photo of a man and a woman" | "A room with a framed picture, a potted plant, and a mirror" | Partial — wrong objects |
| Couple on bench | "A man sitting on the arm of a bench near a woman" | "A couple sitting on a bench in a park" | Good |
| Man playing Wii | "A man holding a tv remote and wii controller" | "A man playing a video game on a Nintendo Wii console" | Good |
| Stop sign | "A close up of the stop sign and two street signs" | "A street sign and a few street signs in the background" | Partial — missed stop sign |
| Bathroom | "A white bath tub sitting next to a toilet" | "A bedroom with a large bed, a dresser, and a TV" | Bad — wrong room |
| Luggage on car | "Suitcases on top of a carrier on a vehicle" | "A suitcase and a backpack, with a blue sky" | Partial — missed vehicle |
| Motorcycle | "An old motorcycle rests near a rundown building" | "A large, old, and dirty brown motorcycle parked in front of a building" | Good |
| Modern bathroom | "A bathroom sink and mirror reflecting the shower" | "A large, modern bathroom with a large mirror, a glass shower, and a sink" | Good |

**Overall:** kosmos-2 correctly identifies the primary subject in ~7/10 images but misses secondary details and occasionally hallucinates wrong objects (bathroom→bedroom).

### Label Quality (llama3.2-vision)

| Image | Expected Objects | Labels Returned | Notes |
|---|---|---|---|
| Train w/ graffiti | train, graffiti | train, subway | Good, subway is close |
| British flag umbrella | umbrella, crowd, city | (empty) | Fail — no labels |
| Teddy bear + photo | teddy bear, photo, plant | plant, frame, shelf, stuffing, photo, man, plant pot, photo frame, shelf | Verbose but accurate |
| Couple on bench | man, woman, bench | man and woman on bench (x2) | OK but duplicated |
| Man playing Wii | man, wii, controller | (timeout) | Fail — 120s timeout |
| Stop sign | stop sign, street signs | (empty) | Fail — no labels |
| Bathroom | bathtub, toilet | bathroom, shower | Generic but relevant |
| Luggage on car | suitcases, car, rack | (empty) | Fail — no labels |
| Motorcycle | motorcycle, building | old, red | Too vague |
| Modern bathroom | sink, mirror, shower | Bathroom, Toilet | Generic but relevant |

**Overall:** Labels are inconsistent — 3/10 returned empty, 1 timed out. When labels are returned, they're reasonably accurate but sometimes too generic or too verbose. The empty responses suggest the structured JSON output parsing is unreliable with llama3.2-vision.

### NSFW Detection

All 10 test images correctly classified as Neutral with >98% confidence. Fastest endpoint at 0.5s average. The one outlier (7.0s) was likely a cold-start loading the model.

## Cross-Platform Comparison

| Metric | AMD RX 7600 | NVIDIA RTX 4070 Ti | Mac M4 Pro |
|---|---|---|---|
| Caption (kosmos-2) | ~10.8s | ~130ms | N/A |
| Labels (llama3.2-vision) | ~11.4s | ~7s | N/A |
| Labels (qwen2.5vl:7b) | Not tested | Not tested | ~10s |
| NSFW | ~1.2s | ~250ms | N/A |
| GPU layers (llama3.2-vision 11B) | 30/41 | 41/41 | 41/41 |
| VRAM | 8GB dedicated | 12GB dedicated | 128GB unified |

**Notes:**
- The kosmos-2 caption speed difference (10.8s vs 130ms on mcarch) is likely due to mcarch running PyTorch with CUDA GPU acceleration vs CPU-only on this AMD machine. The `photoprism/vision:latest` Docker image ships with CUDA PyTorch, not ROCm PyTorch.
- Ollama label speed is comparable across platforms when models fit in VRAM.
- Mac uses `qwen2.5vl` for both captions and labels (no separate kosmos-2/nsfw models).

## Known Issues

- **Empty label responses:** llama3.2-vision sometimes returns empty JSON when asked for structured label output. May improve with prompt tuning or switching to `qwen2.5vl`.
- **Caption hallucination:** kosmos-2 occasionally identifies completely wrong scenes (bathroom→bedroom). This is a known limitation of the model at this resolution.
- **Timeout on labels:** One image timed out at 120s. Increase `GUNICORN_TIMEOUT` or the curl timeout if this is frequent.
- **kosmos-2 running on CPU:** The Docker image bundles CUDA PyTorch, not ROCm PyTorch. Local models (kosmos-2, nsfw_image_detector) run on CPU even with ROCm GPU available. Only Ollama benefits from the AMD GPU.

## TODO

- [ ] Benchmark `qwen2.5vl:3b` and `qwen2.5vl:7b` on AMD for comparison with Mac results
- [ ] Test with larger sample size (n=50 or n=100)
- [ ] Compare `llava-phi3` (fits entirely in 8GB VRAM) vs `llama3.2-vision`
- [ ] Investigate building `photoprism/vision` with ROCm PyTorch for GPU-accelerated local models
- [ ] Run benchmark with SDDM running vs stopped to quantify VRAM impact on speed
