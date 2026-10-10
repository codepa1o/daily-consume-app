import 'dart:convert';

import 'data/travel_planner.dart';

const amapWebKey = String.fromEnvironment('AMAP_WEB_JS_KEY');
const amapWebSecurityCode = String.fromEnvironment('AMAP_WEB_JS_SECURITY_CODE');

String buildTravelMapHtml(List<TravelMapPoint> points) {
  final payload = jsonEncode([
    for (final point in points)
      {
        'name': point.name,
        'type': point.type,
        'typeLabel': point.typeLabel,
        'dayIndex': point.dayIndex,
        'order': point.order,
        'longitude': point.longitude,
        'latitude': point.latitude,
        'address': point.address,
        'description': point.description,
      },
  ])
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('&', r'\u0026');
  final key = Uri.encodeComponent(amapWebKey);
  final securityCode = jsonEncode(amapWebSecurityCode);
  return '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>html,body,#map{width:100%;height:100%;margin:0;background:#f2f4ef;font-family:Arial,sans-serif}.amap-info-content{line-height:1.5}</style>
<script>
window._AMapSecurityConfig={securityJsCode:$securityCode};
const TRIP_POINTS=$payload;
function plainText(tag,value){const node=document.createElement(tag);node.textContent=value||'';return node;}
function startMap(){
  const root=document.getElementById('map');
  if(!window.AMap){root.textContent='地图加载失败，请检查网络或高德地图配置。';return;}
  const map=new AMap.Map(root,{zoom:11,resizeEnable:true,viewMode:'2D'});
  const groups=new Map();
  const colors=['#1677ff','#16a34a','#f59e0b','#8b5cf6','#ef4444','#0f766e'];
  TRIP_POINTS.forEach((point,index)=>{
    const marker=new AMap.Marker({position:[point.longitude,point.latitude],title:point.name});
    marker.setLabel({direction:'top',offset:new AMap.Pixel(0,-4),content:'D'+(point.dayIndex+1)+' '+point.typeLabel});
    marker.on('click',()=>{
      const panel=document.createElement('div');
      const title=plainText('strong',point.name);panel.appendChild(title);
      const kind=plainText('div','第'+(point.dayIndex+1)+'天 · '+point.typeLabel);panel.appendChild(kind);
      if(point.address)panel.appendChild(plainText('div',point.address));
      if(point.description)panel.appendChild(plainText('div',point.description));
      new AMap.InfoWindow({content:panel,offset:new AMap.Pixel(0,-28)}).open(map,marker.getPosition());
    });
    map.add(marker);
    const group=groups.get(point.dayIndex)||[];group.push({...point,index});groups.set(point.dayIndex,group);
  });
  groups.forEach((group,day)=>{
    group.sort((a,b)=>a.order-b.order||a.index-b.index);
    if(group.length>1){
      map.add(new AMap.Polyline({path:group.map(p=>[p.longitude,p.latitude]),strokeColor:colors[day%colors.length],strokeWeight:4,strokeOpacity:.75,showDir:true}));
    }
  });
  if(TRIP_POINTS.length)map.setFitView(null,false,[42,42,42,42]);
}
</script>
<script src="https://webapi.amap.com/maps?v=2.0&key=$key&callback=startMap"></script>
</head><body><div id="map"></div></body></html>''';
}
