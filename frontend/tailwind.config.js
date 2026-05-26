/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      // Named layers for the mobile sidebar stacking context.
      // backdrop < sidebar < toggle so the toggle is always tappable.
      zIndex: {
        backdrop: "1300",
        sidebar: "1400",
        toggle: "1500",
      },
    },
  },
  plugins: [],
};
