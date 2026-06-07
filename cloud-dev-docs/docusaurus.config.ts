import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Claude World',
  tagline: 'A single-container cloud development environment: web terminal + SSH, accessible from anywhere.',
  favicon: 'img/claude_world_logo.png',

  future: {
    v4: true,
  },

  url: 'https://Piero24.github.io',
  baseUrl: '/Claude-World/',

  organizationName: 'Piero24',
  projectName: 'Claude-World',

  onBrokenLinks: 'throw',
  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },
  themes: ['@docusaurus/theme-mermaid'],

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          routeBasePath: 'docs',
          editUrl:
            'https://github.com/Piero24/Claude-World/edit/main/cloud-dev-docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/claude_world_logo.png',
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Claude World',
      logo: {
        alt: 'Claude World Logo',
        src: 'img/claude_world_logo.png',
      },
      items: [
        {
          to: '/docs/',
          label: 'Home',
          position: 'left',
        },
        {
          to: '/docs/server-setup',
          label: 'Getting Started',
          position: 'left',
        },
        {
          to: '/docs/env-vars',
          label: 'Reference',
          position: 'left',
        },
        {
          href: 'https://github.com/Piero24/Claude-World',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'Overview & Architecture', to: '/docs/'},
            {label: 'Server Setup', to: '/docs/server-setup'},
            {label: 'Daily Workflow', to: '/docs/daily-workflow'},
            {label: 'Environment Variables', to: '/docs/env-vars'},
            {label: 'Persistence', to: '/docs/persistence'},
          ],
        },
        {
          title: 'Resources',
          items: [
            {label: 'linuxserver/webtop', href: 'https://docs.linuxserver.io/images/docker-webtop/'},
            {label: 'ttyd', href: 'https://github.com/tsl0922/ttyd'},
            {label: 'CasaOS', href: 'https://casaos.io/'},
          ],
        },
        {
          title: 'More',
          items: [
            {label: 'GitHub', href: 'https://github.com/Piero24/Claude-World'},
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Claude World. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'yaml', 'json'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
