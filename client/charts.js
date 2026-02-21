function clamp(v, min, max) {
  return Math.max(min, Math.min(max, v));
}

export class ScrollingChart {
  constructor(canvas, options) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");

    this.windowSec = options.windowSec ?? 60;
    this.yMin = options.yMin ?? -1;
    this.yMax = options.yMax ?? 1;
    this.series = options.series ?? [];
    this.background = options.background ?? "#0f1a24";
    this.gridColor = options.gridColor ?? "rgba(220,230,245,0.12)";
    this.markerColor = options.markerColor ?? "#ffab40";

    this.samples = new Map();
    for (const item of this.series) {
      this.samples.set(item.key, []);
    }
    this.markers = [];

    this._resizeCanvas();
    window.addEventListener("resize", () => this._resizeCanvas());
  }

  addSample(tSec, sample) {
    const cutoff = tSec - this.windowSec;

    for (const line of this.series) {
      const value = sample[line.key];
      if (!Number.isFinite(value)) {
        continue;
      }
      const bucket = this.samples.get(line.key);
      bucket.push({ t: tSec, v: value });
      while (bucket.length && bucket[0].t < cutoff) {
        bucket.shift();
      }
    }

    while (this.markers.length && this.markers[0].t < cutoff) {
      this.markers.shift();
    }
  }

  addMarker(tSec, label = "MARK") {
    this.markers.push({ t: tSec, label });
  }

  render(nowSec) {
    this._resizeCanvas();

    const ctx = this.ctx;
    const w = this.canvas.width;
    const h = this.canvas.height;

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = this.background;
    ctx.fillRect(0, 0, w, h);

    this._drawGrid(ctx, w, h);

    const xMin = nowSec - this.windowSec;
    const xMax = nowSec;

    for (const line of this.series) {
      const points = this.samples.get(line.key);
      if (!points || points.length < 2) {
        continue;
      }

      ctx.beginPath();
      ctx.lineWidth = 2;
      ctx.strokeStyle = line.color;

      let started = false;
      for (const p of points) {
        if (p.t < xMin || p.t > xMax) {
          continue;
        }
        const x = ((p.t - xMin) / (xMax - xMin)) * w;
        const y = h - ((p.v - this.yMin) / (this.yMax - this.yMin)) * h;

        if (!started) {
          ctx.moveTo(x, y);
          started = true;
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();
    }

    for (const marker of this.markers) {
      const alpha = (marker.t - xMin) / (xMax - xMin);
      if (alpha < 0 || alpha > 1) {
        continue;
      }
      const x = alpha * w;
      ctx.beginPath();
      ctx.strokeStyle = this.markerColor;
      ctx.lineWidth = 1.5;
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h);
      ctx.stroke();
    }

    this._drawLegend(ctx, w);
  }

  _drawGrid(ctx, w, h) {
    ctx.save();
    ctx.strokeStyle = this.gridColor;
    ctx.lineWidth = 1;

    const vertical = 6;
    for (let i = 1; i < vertical; i += 1) {
      const x = (i / vertical) * w;
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h);
      ctx.stroke();
    }

    const horizontal = 4;
    for (let i = 1; i < horizontal; i += 1) {
      const y = (i / horizontal) * h;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }
    ctx.restore();
  }

  _drawLegend(ctx, w) {
    ctx.save();
    ctx.font = "12px ui-sans-serif, system-ui";
    ctx.textBaseline = "top";

    let x = 12;
    for (const line of this.series) {
      ctx.fillStyle = line.color;
      ctx.fillRect(x, 10, 10, 10);
      ctx.fillStyle = "#e8eef7";
      ctx.fillText(line.label, x + 14, 8);
      x += ctx.measureText(line.label).width + 38;
      if (x > w - 100) {
        x = 12;
      }
    }

    ctx.restore();
  }

  _resizeCanvas() {
    const rect = this.canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(200, Math.floor(rect.width * dpr));
    const height = Math.max(120, Math.floor(rect.height * dpr));

    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
  }
}
