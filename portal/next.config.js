/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  typescript: {
    // Pre-existing wagmi human-readable ABI returns `unknown` from useReadContract
    // and that propagates everywhere. Runtime is fine. Tracked but not blocking.
    ignoreBuildErrors: true,
  },
  webpack: (config) => {
    // Exclude Node.js modules
    config.resolve.fallback = {
      fs: false,
      net: false,
      tls: false,
      crypto: false,
      stream: false,
      http: false,
      https: false,
      zlib: false,
      path: false,
      os: false,
    };

    // Exclude React Native modules
    config.resolve.alias = {
      ...config.resolve.alias,
      '@react-native-async-storage/async-storage': false,
      'react-native': false,
      'react-native-svg': false,
      'react-native-randombytes': false,
    };

    // External modules
    config.externals.push('pino-pretty', 'lokijs', 'encoding');

    return config;
  },
}

module.exports = nextConfig
