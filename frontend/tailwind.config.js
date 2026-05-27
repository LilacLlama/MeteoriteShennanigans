/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      // Named layers (low → high):
      //   overlay  — map-floating UI (selected-meteorite card, heatmap legend)
      //   backdrop — mobile sidebar tap-out backdrop
      //   sidebar  — mobile sidebar panel itself
      //   toggle   — mobile sidebar toggle button, always tappable on top
      zIndex: {
        overlay: "1000",
        backdrop: "1300",
        sidebar: "1400",
        toggle: "1500",
      },
    },
  },
  plugins: [],
};
