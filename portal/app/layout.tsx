import './globals.css'
import '@rainbow-me/rainbowkit/styles.css'
import type {Metadata} from 'next'
import {Inter, JetBrains_Mono} from 'next/font/google'
import dynamic from 'next/dynamic'

const Providers = dynamic(() => import('./providers').then((mod) => mod.Providers), {
  ssr: false,
})

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-sans',
  display: 'swap',
})

const mono = JetBrains_Mono({
  subsets: ['latin'],
  variable: '--font-mono',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'Hedge Fund Portal',
  description: 'DeFi Hedge Fund Management Portal',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
