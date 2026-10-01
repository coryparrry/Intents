import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
} from "remotion";

import { Backdrop } from "../Backdrop";

const smooth = {
  easing: Easing.bezier(0.22, 1, 0.36, 1),
  extrapolateLeft: "clamp",
  extrapolateRight: "clamp",
} as const;

export const Logo = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill
      style={{
        fontFamily: "Helvetica Neue,Arial,sans-serif",
        perspective: 1400,
      }}
    >
      <Backdrop />
      <div
        style={{
          borderRadius: 18,
          height: 936,
          left: 252,
          opacity: interpolate(frame, [0, 42], [1, 0], smooth),
          overflow: "hidden",
          position: "absolute",
          scale: interpolate(frame, [0, 42], [1, 0.98], smooth),
          top: 72,
          width: 1416,
        }}
      >
        <Img
          src={staticFile("user-last-frame.png")}
          style={{ height: "100%", width: "100%" }}
        />
      </div>
      <div
        style={{
          borderRadius: 82,
          boxShadow: "0 24px 65px #356db32b",
          height: 360,
          left: 780,
          opacity: interpolate(frame, [26, 70], [0, 1], smooth),
          overflow: "hidden",
          position: "absolute",
          top: 285,
          transform: `translateY(${interpolate(frame, [26, 110], [45, 0], smooth)}px) scale(${interpolate(frame, [26, 110], [0.72, 1], smooth)}) rotateY(${interpolate(frame, [26, 110], [-24, 0], smooth)}deg)`,
          width: 360,
        }}
      >
        <Img
          src={staticFile("app-logo.png")}
          style={{ height: "100%", scale: 1.12, width: "100%" }}
        />
        <div
          style={{
            background:
              "linear-gradient(115deg,transparent 40%,#ffffff70 49%,transparent 58%)",
            inset: -150,
            position: "absolute",
            translate: `${interpolate(frame, [90, 165], [-650, 650], smooth)}px 0`,
          }}
        />
      </div>
      <div
        style={{
          color: "#254266",
          fontSize: 62,
          fontWeight: 600,
          letterSpacing: -2,
          opacity: interpolate(frame, [68, 115], [0, 1], smooth),
          textAlign: "center",
          top: 700,
          translate: `0 ${interpolate(frame, [68, 115], [15, 0], smooth)}px`,
          width: "100%",
          position: "absolute",
        }}
      >
        Foundation Evals
      </div>
    </AbsoluteFill>
  );
};
