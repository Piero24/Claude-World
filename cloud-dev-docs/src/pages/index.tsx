import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={clsx('hero hero--primary', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--secondary button--lg"
            to="/docs/">
            Read the docs
          </Link>
        </div>
      </div>
    </header>
  );
}

export default function Home() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description="A single-container cloud development environment with web terminal and SSH">
      <HomepageHeader />
      <main>
        <div className="container" style={{padding: '3rem 0'}}>
          <div className="row">
            <div className="col col--4">
              <h3>🖥️ Web Terminal</h3>
              <p>
                Full bash shell in your browser via ttyd. Password-protected,
                works from any device, no client needed.
              </p>
            </div>
            <div className="col col--4">
              <h3>🔧 Pre-installed Tools</h3>
              <p>
                nvm + Node LTS, Claude Code, Python 3, Java, Docker CLI,
                build-essential, tmux, zsh ready on first boot.
              </p>
            </div>
            <div className="col col--4">
              <h3>📦 One Container</h3>
              <p>
                Everything in one container. Persistent /config survives
                rebuilds. Deploy on CasaOS or plain Docker in minutes.
              </p>
            </div>
          </div>
        </div>
      </main>
    </Layout>
  );
}
