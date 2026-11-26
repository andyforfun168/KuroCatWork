import AppKit
import CoreText

final class WorkPanelDrawing {
 var actionHover: [String:CGFloat] = [:]
 var p: CatPhysics
 init(_ physics: CatPhysics) { p=physics }
let blue=NSColor(calibratedRed:0.22,green:0.56,blue:0.91,alpha:1)
let orange=NSColor(calibratedRed:0.91,green:0.50,blue:0.25,alpha:1)
let yellow=NSColor(calibratedRed:0.72,green:0.53,blue:0.09,alpha:1)
let purple=NSColor(calibratedRed:0.58,green:0.35,blue:0.80,alpha:1)
let green=NSColor(calibratedRed:0.20,green:0.61,blue:0.40,alpha:1)
let red=NSColor(calibratedRed:0.84,green:0.26,blue:0.31,alpha:1)
let ink=NSColor(calibratedRed:0.22,green:0.25,blue:0.29,alpha:1)
func ease(_ x:CGFloat)->CGFloat{let v=max(0,min(1,x));return v*v*(3-2*v)}
func mix(_ a:CGFloat,_ b:CGFloat,_ v:CGFloat)->CGFloat{a+(b-a)*v}
func mixP(_ a:CGPoint,_ b:CGPoint,_ v:CGFloat)->CGPoint{CGPoint(x:mix(a.x,b.x,v),y:mix(a.y,b.y,v))}
func rotate(_ p:CGPoint,_ angle:CGFloat)->CGPoint{CGPoint(x:p.x*cos(angle)-p.y*sin(angle),y:p.x*sin(angle)+p.y*cos(angle))}
func text(_ c:CGContext,_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor=NSColor(calibratedRed:0.22,green:0.25,blue:0.29,alpha:1),_ bold:Bool=false){
 c.saveGState();c.translateBy(x:x,y:y+size);c.scaleBy(x:1,y:-1);c.textMatrix = .identity;c.textPosition = .zero
 let a=NSAttributedString(string:value,attributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular),.foregroundColor:color])
 CTLineDraw(CTLineCreateWithAttributedString(a),c);c.restoreGState()
}
func rounded(_ rect:CGRect,_ radius:CGFloat)->CGPath{CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil)}
func bubble(_ c:CGContext,_ rect:CGRect,_ tint:NSColor,_ r:CGFloat=9,extruded:Bool=true){
 if extruded {
 c.saveGState();c.setShadow(offset:CGSize(width:0,height:-2.5),blur:4,color:NSColor.black.withAlphaComponent(0.10).cgColor)
 c.setFillColor(tint.blended(withFraction:0.70,of:.darkGray)!.cgColor)
 c.addPath(rounded(rect.offsetBy(dx:0,dy:2.6),r));c.fillPath();c.restoreGState()
 }
 c.setFillColor(NSColor(calibratedRed:0.985,green:0.982,blue:0.965,alpha:1).cgColor);c.addPath(rounded(rect,r));c.fillPath()
 c.setStrokeColor(tint.withAlphaComponent(0.50).cgColor);c.setLineWidth(0.8);c.addPath(rounded(rect.insetBy(dx:0.4,dy:0.4),r));c.strokePath()
 c.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor);c.setLineWidth(0.65);c.move(to:CGPoint(x:rect.minX+9,y:rect.minY+1.7));c.addLine(to:CGPoint(x:rect.maxX-9,y:rect.minY+1.7));c.strokePath()
}
func perimeterPoint(_ t:CGFloat,_ w:CGFloat,_ h:CGFloat)->CGPoint{
 let r=h/2,L=w-2*r,arc=CGFloat.pi*r,total=2*L+2*arc
 var d=t*total
 if d<L{return CGPoint(x:-L/2+d,y:-r)};d-=L
 if d<arc{let a = -CGFloat.pi/2+d/r;return CGPoint(x:L/2+r*cos(a),y:r*sin(a))};d-=arc
 if d<L{return CGPoint(x:L/2-d,y:r)};d-=L
 let a=CGFloat.pi/2+d/r;return CGPoint(x:-L/2+r*cos(a),y:r*sin(a))
}
func weekRing(_ c:CGContext,_ w:CGFloat,_ h:CGFloat,_ days:CGFloat,_ color:NSColor){
 c.saveGState();c.setLineCap(.round);c.setLineJoin(.round)
 // Solid and empty sections share a full-width 2.3pt track.
 // Paint opaque white first, then a fine tool-color boundary outside it.
 let centerline=rounded(CGRect(x:-w/2,y:-h/2,width:w,height:h),h/2)
 c.setStrokeColor(color.withAlphaComponent(0.95).cgColor);c.setLineWidth(3.1)
 c.addPath(centerline);c.strokePath()
 c.setStrokeColor(NSColor.white.cgColor);c.setLineWidth(2.3)
 c.addPath(centerline);c.strokePath()
 let remaining=max(0,min(1,days/7))
 if remaining>0 {
  let path=CGMutablePath()
  for j in 0...240 {
   let pt=perimeterPoint(remaining*CGFloat(j)/240,w,h)
   if j==0{path.move(to:pt)}else{path.addLine(to:pt)}
  }
  c.setStrokeColor(color.withAlphaComponent(0.95).cgColor);c.setLineWidth(2.3);c.addPath(path);c.strokePath()
 }
 // Six subtle dividers distinguish seven days without cutting holes in the track.
 c.setLineCap(.butt);c.setLineWidth(0.65)
 c.setStrokeColor(color.blended(withFraction:0.46,of:.darkGray)!.withAlphaComponent(0.85).cgColor)
 for divider in 1..<7 {
  let fraction=CGFloat(divider)/7
  let center=perimeterPoint(fraction,w,h)
  let before=perimeterPoint(fraction-0.0001,w,h),after=perimeterPoint(fraction+0.0001,w,h)
  let dx=after.x-before.x,dy=after.y-before.y,length=max(0.0001,hypot(dx,dy))
  let nx = -dy/length,ny=dx/length
  c.move(to:CGPoint(x:center.x+nx*1.0,y:center.y+ny*1.0))
  c.addLine(to:CGPoint(x:center.x-nx*1.0,y:center.y-ny*1.0));c.strokePath()
 }
 c.restoreGState()
}
func quota(_ c:CGContext,_ name:String,_ color:NSColor,_ x:CGFloat,_ remaining:CGFloat,_ week:CGFloat,_ days:CGFloat,_ barWidth:CGFloat=90,_ hasShortWindow:Bool=true,_ hasWeek:Bool=true){
 c.saveGState();c.translateBy(x:x,y:0)
 let box=CGRect(x:-barWidth/2,y:-14,width:barWidth,height:28)
 bubble(c,box,color,12)
 let interior=box.insetBy(dx:1.6,dy:1.6)
 c.saveGState();c.addPath(rounded(interior,interior.height/2));c.clip()
 let fraction=max(0,min(1,hasShortWindow ? remaining : week))
 if fraction>0 {
  let fill=CGRect(x:interior.minX,y:interior.minY,width:interior.width*fraction,height:interior.height)
  c.setFillColor(color.withAlphaComponent(0.24).cgColor)
  c.fill(fill)
 }
 if hasShortWindow && hasWeek {
  c.setFillColor(color.withAlphaComponent(0.18).cgColor);c.fill(CGRect(x:-barWidth/2+11,y:6.8,width:barWidth-22,height:3.2))
  c.setFillColor(color.withAlphaComponent(0.85).cgColor);c.fill(CGRect(x:-barWidth/2+11,y:6.8,width:(barWidth-22)*week,height:3.2))
 }
 c.restoreGState()
 text(c,name,-barWidth/2+14,-7.8,8.7,color,true)
 if hasWeek {weekRing(c,barWidth-1,27,days,color)}
 c.restoreGState()
}
func elapsed(_ seconds:Int)->String{String(format:"%02d:%02d",seconds/60,seconds%60)}
func task(_ c:CGContext,_ title:String,_ detail:String,_ tool:String,_ toolColor:NSColor,_ state:NSColor,_ action:String?){
 let rect=CGRect(x:-95,y:-15,width:190,height:30);bubble(c,rect,state,8)
 c.saveGState();c.setStrokeColor(state.withAlphaComponent(0.95).cgColor);c.setLineWidth(2.0)
 c.addPath(rounded(rect.insetBy(dx:1,dy:1),7));c.strokePath();c.restoreGState()
 c.setFillColor(toolColor.cgColor);c.addPath(rounded(CGRect(x:-89,y:-9,width:2.3,height:18),1));c.fillPath()
 c.setFillColor(state.cgColor);c.fillEllipse(in:CGRect(x:-81,y:-7,width:3.5,height:3.5))
 let titleRoom:CGFloat=action == nil ? 157 : 104
 var label=title
 while NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:8.1,weight:.semibold)]).size().width>titleRoom && label.count>1 {label=String(label.dropLast(2))+"…"}
 text(c,label,-72,-11.1,8.1,ink,true)
 text(c,detail,-80,1,6.1,state)
 if let action=action {
  let b=CGRect(x:36,y:-10.5,width:52,height:21)
  let hover=p.isScruffDragging ? 0 : (actionHover[title] ?? 0)
  c.saveGState();c.translateBy(x:b.midX,y:b.midY);c.scaleBy(x:1+0.075*hover,y:1+0.075*hover);c.translateBy(x:-b.midX,y:-b.midY)
  c.setFillColor(state.withAlphaComponent(p.isScruffDragging ? 0.05 : 0.13+0.06*hover).cgColor)
  c.addPath(rounded(b,6));c.fillPath()
  text(c,action,47,-5.1,7.4,p.isScruffDragging ? NSColor.tertiaryLabelColor : state,true)
  c.restoreGState()
 }
}

}
