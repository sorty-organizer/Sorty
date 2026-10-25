// Dia Browser's signature gradient as a static SVG.
//
// A row of N tall, heavily-blurred columns share one vertical rainbow gradient
// and are arranged in a symmetric bell curve (short at the edges, tallest in the
// middle). The field stays static so scrolling never rerasterizes a large
// blurred layer.
//
// Usage:
//   <div className="absolute inset-x-0 bottom-0 h-[55vh] pointer-events-none">
//     <DiaGradient />
//   </div>

type Stop = { offset: number; color: string }

// Sorty's blue take on the Dia footer: same dark-to-bright-to-clear rhythm as
// the reference, mapped into navy, electric blue, ice, and transparent cyan.
const DIA_STOPS: Stop[] = [
  { offset: 0, color: '#020617' },
  { offset: 0.1827, color: '#0358F7' },
  { offset: 0.2837, color: '#38BDF8' },
  { offset: 0.4135, color: '#E1F4FF' },
  { offset: 0.5866, color: '#8BE8FF' },
  { offset: 0.6827, color: '#2563EB' },
  { offset: 0.8029, color: '#1D4ED8' },
  { offset: 1, color: '#E0F2FE00' },
]

const VBW = 1271
const VBH = 599

// Height curve fitted to the real Dia footer: a gentle power falloff (not a
// cosine bell), giving the flatter, pyramid-like rise of the original.
function bellHeights(n: number, peak: number, valley: number): number[] {
  const out: number[] = []
  const mid = (n - 1) / 2
  for (let i = 0; i < n; i++) {
    const t = mid === 0 ? 0 : Math.abs(i - mid) / mid // 0 center → 1 edge
    const eased = 1 - Math.pow(t, 1.24) // 1 at center → 0 at edge
    out.push(peak * VBH * (valley + (1 - valley) * eased))
  }
  return out
}

export function DiaGradient({
  bars = 9,
  blur = 15,
  peak = 0.98,
  valley = 0.55,
  stops = DIA_STOPS,
  strength = 1,
  animateOnScroll = false,
}: {
  bars?: number
  blur?: number
  peak?: number
  valley?: number
  stops?: Stop[]
  /** Peak opacity of the painted field (0..1). */
  strength?: number
  animateOnScroll?: boolean
}) {
  const heights = bellHeights(bars, peak, valley)
  const colW = VBW / bars

  return (
    <div
      aria-hidden
      className={animateOnScroll ? 'dia-gradient dia-gradient-scroll' : 'dia-gradient'}
    >
      <svg
        style={{ height: '100%', width: '100%', opacity: strength }}
        viewBox={`0 0 ${VBW} ${VBH}`}
        preserveAspectRatio="none"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          {/* objectBoundingBox units (default): the gradient maps to each rect's
              own box, so every bar shows the full rainbow over its own height —
              a field of full-rainbow columns, the way the real Dia footer does it. */}
          <linearGradient id="dia-grad" x1="0" y1="1" x2="0" y2="0">
            {stops.map((s, i) => (
              <stop key={i} offset={s.offset} stopColor={s.color} />
            ))}
          </linearGradient>
          <filter id="dia-blur" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation={blur} />
          </filter>
        </defs>
        <g filter="url(#dia-blur)">
          {heights.map((h, i) => (
            <rect
              key={i}
              x={i * colW}
              y={VBH - h}
              width={colW * 1.23}
              height={h}
              fill="url(#dia-grad)"
            />
          ))}
        </g>
      </svg>
    </div>
  )
}
