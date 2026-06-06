import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Welcome',
      items: ['index'],
    },
    {
      type: 'category',
      label: 'Getting Started',
      items: ['server-setup'],
    },
    {
      type: 'category',
      label: 'Daily Use',
      items: ['daily-workflow', 'persistence'],
    },
    {
      type: 'category',
      label: 'Reference',
      items: ['env-vars'],
    },
  ],
};

export default sidebars;
