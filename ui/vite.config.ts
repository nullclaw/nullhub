import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig, type ProxyOptions } from 'vite';

function createLocalApiProxy(): ProxyOptions {
  return {
    target: 'http://127.0.0.1:19800',
    configure(proxy) {
      proxy.on('proxyReq', (proxyReq) => {
        // Keep local dev requests same-origin from the browser's perspective.
        proxyReq.removeHeader('origin');
      });
    }
  };
}

export default defineConfig({
  plugins: [sveltekit()],
  server: {
    proxy: {
      '/api': createLocalApiProxy()
    }
  },
  preview: {
    proxy: {
      '/api': createLocalApiProxy()
    }
  }
});
