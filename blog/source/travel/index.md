---
title: 旅行足迹
date: 2026-05-05 00:00:00
---

<div class="travel-page">

<p class="travel-intro">这里记录我曾踏足过的地方 — 地图上高亮的部分是已到访的国家与地区。</p>

<div class="travel-stats">
  <div class="stat-item">
    <span class="stat-number">9</span>
    <span class="stat-label">国家 / 地区</span>
  </div>
  <div class="stat-item">
    <span class="stat-number">2</span>
    <span class="stat-label">大洲</span>
  </div>
</div>

<div id="travel-map"></div>

<h2>到访清单</h2>

<div class="destination-grid">
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/cn.png" alt="中国"><span class="name">中国</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/jp.png" alt="日本"><span class="name">日本</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/kr.png" alt="韩国"><span class="name">韩国</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/tw.png" alt="台湾"><span class="name">台湾</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/hk.png" alt="香港"><span class="name">香港</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/mo.png" alt="澳门"><span class="name">澳门</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/th.png" alt="泰国"><span class="name">泰国</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/gb.png" alt="英国"><span class="name">英国</span></div>
  <div class="destination-card"><img class="flag" src="https://flagcdn.com/w40/it.png" alt="意大利"><span class="name">意大利</span></div>
</div>

</div>

<style>
.travel-page { margin: 0 auto; }
.travel-intro {
  font-size: 1.05em;
  color: #666;
  margin-bottom: 1.5em;
}
.travel-stats {
  display: flex;
  gap: 2em;
  margin: 1.5em 0 2em;
  padding: 1em 0;
  border-top: 1px solid #eee;
  border-bottom: 1px solid #eee;
}
.stat-item {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}
.stat-number {
  font-size: 2em;
  font-weight: 600;
  color: #2bbc8a;
  line-height: 1;
}
.stat-label {
  font-size: 0.85em;
  color: #888;
  margin-top: 0.25em;
}
#travel-map {
  width: 100%;
  height: 520px;
  margin: 1.5em 0 2em;
  background: #fafafa;
  border-radius: 4px;
}
.destination-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
  gap: 0.75em;
  margin: 1em 0 2em;
}
.destination-card {
  display: flex;
  align-items: center;
  gap: 0.6em;
  padding: 0.7em 0.9em;
  background: #fafafa;
  border: 1px solid #eee;
  border-radius: 4px;
  transition: transform 0.15s ease, border-color 0.15s ease;
}
.destination-card:hover {
  transform: translateY(-2px);
  border-color: #2bbc8a;
}
.destination-card .flag {
  width: 28px;
  height: 21px;
  object-fit: cover;
  border-radius: 2px;
  box-shadow: 0 0 0 1px rgba(0,0,0,0.08);
  flex-shrink: 0;
}
.destination-card .name {
  font-size: 0.95em;
  color: #383838;
}
@media (max-width: 600px) {
  #travel-map { height: 360px; }
  .travel-stats { gap: 1.5em; }
}
</style>

<script src="https://cdn.amcharts.com/lib/5/index.js"></script>
<script src="https://cdn.amcharts.com/lib/5/map.js"></script>
<script src="https://cdn.amcharts.com/lib/5/geodata/worldLow.js"></script>
<script src="https://cdn.amcharts.com/lib/5/themes/Animated.js"></script>
<script>
am5.ready(function () {
  var root = am5.Root.new("travel-map");
  root.setThemes([am5themes_Animated.new(root)]);

  var chart = root.container.children.push(
    am5map.MapChart.new(root, {
      panX: "translateX",
      panY: "translateY",
      projection: am5map.geoMercator(),
      homeZoomLevel: 1.1,
      homeGeoPoint: { longitude: 60, latitude: 30 }
    })
  );

  var visited = ["JP", "KR", "TW", "CN", "GB", "IT", "TH", "HK", "MO"];
  var visitedColor = am5.color(0x2bbc8a);
  var defaultColor = am5.color(0xe6e6e6);
  var hoverColor = am5.color(0x1f8c66);

  var polygonSeries = chart.series.push(
    am5map.MapPolygonSeries.new(root, {
      geoJSON: am5geodata_worldLow,
      exclude: ["AQ"]
    })
  );

  polygonSeries.mapPolygons.template.setAll({
    fill: defaultColor,
    stroke: am5.color(0xffffff),
    strokeWidth: 0.5,
    tooltipText: "{name}",
    interactive: true
  });

  polygonSeries.mapPolygons.template.states.create("hover", {
    fill: am5.color(0xc8c8c8)
  });

  polygonSeries.mapPolygons.template.adapters.add("fill", function (fill, target) {
    var di = target.dataItem;
    if (di && visited.indexOf(di.dataContext.id) !== -1) {
      return visitedColor;
    }
    return fill;
  });

  polygonSeries.mapPolygons.template.adapters.add("tooltipText", function (text, target) {
    var di = target.dataItem;
    if (di && visited.indexOf(di.dataContext.id) !== -1) {
      return "{name} ✓";
    }
    return text;
  });

  // Markers for small territories that may render too small to see at world scale.
  var pointSeries = chart.series.push(
    am5map.MapPointSeries.new(root, {})
  );
  pointSeries.bullets.push(function () {
    var circle = am5.Circle.new(root, {
      radius: 5,
      fill: visitedColor,
      stroke: am5.color(0xffffff),
      strokeWidth: 1.5,
      tooltipText: "{title}"
    });
    return am5.Bullet.new(root, { sprite: circle });
  });

  var markers = [
    { title: "香港", longitude: 114.1694, latitude: 22.3193 },
    { title: "澳门", longitude: 113.5439, latitude: 22.1987 }
  ];
  markers.forEach(function (m) {
    pointSeries.data.push({
      geometry: { type: "Point", coordinates: [m.longitude, m.latitude] },
      title: m.title
    });
  });

  chart.appear(1000, 100);
});
</script>
