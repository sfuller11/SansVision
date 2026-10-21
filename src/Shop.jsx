const BUNDLES = [["Tiny", 10], ["Small", 25], ["Medium", 60], ["Large", 140], ["Huge", 300], ["Ultra", 650], ["Mega", 1400]];

// Display only for now: nothing here can charge anyone or add gems.
export default function Shop() {
  return (
    <div>
      <h2>Gem bundles</h2>
      <p className="mute">Collector Gems skip growth stages and power Collector Discovery. Buying gems is not available yet.</p>
      <div className="grid">
        {BUNDLES.map(([name, gems]) => (
          <div key={name} className="plant">
            <div className="gicon" aria-hidden="true">💎</div>
            <h2>{name}</h2>
            <p><b>{gems}</b> Collector Gems</p>
            <button disabled>Coming soon</button>
          </div>
        ))}
      </div>
      <div className="panel" style={{ marginTop: 20 }}>
        <h2>Special Varieties</h2>
        <p className="mute">Coming Soon: rare cultivars you will be able to buy directly.</p>
      </div>
    </div>
  );
}
