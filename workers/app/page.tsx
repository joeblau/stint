import Image from "next/image";
import styles from "./page.module.css";

const features = [
  {
    title: "Every circuit, one tap",
    body: "Fly from a chase-camera over the kerbs to a season globe in a single, smooth zoom.",
  },
  {
    title: "Same track. A deeper story.",
    body: "Import OpenF1 session data and watch the actual field carve through every corner.",
  },
  {
    title: "Onboard telemetry",
    body: "Speed, gear, RPM, throttle, brake, and DRS — a living gauge for any driver you follow.",
  },
  {
    title: "Native and offline-ready",
    body: "SwiftUI, MapKit, and SceneKit. Maps are cached ahead of time so flights never stutter.",
  },
];

export default function Home() {
  return (
    <main className={styles.main}>
      <section className={styles.hero}>
        <Image src="/icon.png" alt="Stint app icon" width={128} height={128} className={styles.icon} priority />
        <h1 className={styles.title}>
          <Image src="/wordmark.svg" alt="Stint" width={2515} height={436} className={styles.wordmark} priority />
        </h1>
        <span className={styles.speedBar} aria-hidden="true" />
        <p className={styles.tagline}>Live racing. Deeper insights.</p>
        <p className={styles.sub}>
          More than a race. Every stint. A native race viewer for Mac and iPad that relives every
          Grand Prix from the cockpit, the pit wall, or orbit.
        </p>
        <div className={styles.actions}>
          <a className={styles.primary} href="https://github.com/joeblau/stint/releases/latest/download/Stint-macOS.zip">
            Download for Mac
            <span className={styles.primaryNote}>macOS 26+</span>
          </a>
          <span className={styles.secondaryDisabled} aria-disabled="true" title="iPad build coming soon">
            iPad · soon
          </span>
        </div>
      </section>

      <section className={styles.featuresSection}>
        <p className={styles.kicker}>Cars. Data. Strategy. Every stint.</p>
        <h2 className={styles.featuresTitle}>Built for a faster perspective.</h2>
        <div className={styles.features}>
          {features.map((feature) => (
            <article key={feature.title} className={styles.card}>
              <h3>{feature.title}</h3>
              <p>{feature.body}</p>
            </article>
          ))}
        </div>
      </section>

      <footer className={styles.footer}>
        <p>Stint · Built with SwiftUI, MapKit, and SceneKit</p>
      </footer>
    </main>
  );
}
