import type {Config} from 'tailwindcss'

const config: Config = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  darkMode: 'media',
  theme: {
    extend: {
      fontFamily: {
        sans: ['var(--font-sans)', 'ui-sans-serif', 'system-ui'],
        mono: ['var(--font-mono)', 'ui-monospace', 'SFMono-Regular'],
      },
      colors: {
        // Indigo-violet primary scale — a touch more modern than plain blue.
        primary: {
          50: '#f0f4ff',
          100: '#e0e9ff',
          200: '#c7d4fe',
          300: '#a4b6fc',
          400: '#7e8df8',
          500: '#5d6cf2',
          600: '#4f53e6',
          700: '#4341cc',
          800: '#3938a4',
          900: '#2f3082',
        },
        // Surface scale tuned for both light and dark
        surface: {
          0: '#ffffff',
          50: '#fafafb',
          100: '#f4f4f7',
          200: '#e7e7ed',
          300: '#d3d3dc',
          400: '#9b9bab',
          500: '#6e6e7e',
          600: '#4a4a58',
          700: '#2f2f3a',
          800: '#1c1c25',
          900: '#0e0e15',
          950: '#070710',
        },
        accent: {
          emerald: '#10b981',
          amber: '#f59e0b',
          rose: '#f43f5e',
          sky: '#0ea5e9',
        },
      },
      boxShadow: {
        soft: '0 1px 2px rgba(15, 15, 25, 0.04), 0 4px 12px rgba(15, 15, 25, 0.04)',
        card: '0 1px 3px rgba(15, 15, 25, 0.04), 0 8px 24px -8px rgba(15, 15, 25, 0.08)',
        glow: '0 0 0 1px rgba(93, 108, 242, 0.15), 0 8px 32px -8px rgba(93, 108, 242, 0.35)',
      },
      backgroundImage: {
        'mesh-light':
          'radial-gradient(1200px 600px at 0% -10%, rgba(93,108,242,0.08), transparent), radial-gradient(900px 500px at 100% 0%, rgba(16,185,129,0.05), transparent)',
        'mesh-dark':
          'radial-gradient(1200px 600px at 0% -10%, rgba(93,108,242,0.18), transparent), radial-gradient(900px 500px at 100% 0%, rgba(16,185,129,0.10), transparent)',
      },
      keyframes: {
        shimmer: {
          '0%': {backgroundPosition: '-1000px 0'},
          '100%': {backgroundPosition: '1000px 0'},
        },
        'fade-in': {
          '0%': {opacity: '0', transform: 'translateY(4px)'},
          '100%': {opacity: '1', transform: 'translateY(0)'},
        },
      },
      animation: {
        shimmer: 'shimmer 1.6s linear infinite',
        'fade-in': 'fade-in 200ms ease-out',
      },
    },
  },
  plugins: [],
}
export default config
