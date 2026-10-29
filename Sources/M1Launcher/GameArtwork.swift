// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

/// Public artwork candidates only. Constructed Steam URLs are unverified
/// attempts until ArtworkCache downloads and decodes an actual image.
enum GameArtwork {
  enum Role:String,Codable,CaseIterable {case card,banner,icon}
  static func steamAppID(_ game:Game)->String? {
    guard game.store == .steam,!game.storeID.isEmpty,game.storeID.utf8.count<=10,
      game.storeID.utf8.allSatisfy({(48...57).contains($0)}),let value=UInt32(game.storeID),value>0,String(value)==game.storeID else{return nil}
    return String(value)
  }
  private static func string(_ key:String,_ game:Game)->String?{game.metadata?[key]?.foundation as?String}
  private static func unique(_ addresses:[String?])->[String]{
    var seen=Set<String>()
    return addresses.compactMap{$0}.filter{address in
      guard seen.insert(address).inserted,let url=URL(string:address),url.scheme?.lowercased()=="https",url.host != nil,url.user==nil,url.password==nil else{return false}
      return true
    }
  }
  private static func portrait(_ address:String?)->Bool {
    guard let path=address.flatMap({URL(string:$0)?.path.lowercased()})else{return false}
    return path.contains("600x900") || path.contains("library_capsule") || path.contains("portrait")
  }
  static func candidates(for game:Game,role:Role)->[String]{
    let icon=string("iconURL",game),capsule=string("capsuleURL",game),hero=string("heroURL",game),banner=string("bannerURL",game)
    guard let id=steamAppID(game)else{
      switch role {
      case .card:return unique([capsule,game.artworkURL,icon])
      case .banner:return unique([hero,banner,game.artworkURL].filter{$0 != icon})
      case .icon:return unique([icon,game.artworkURL])
      }
    }
    let base="https://cdn.akamai.steamstatic.com/steam/apps/"+id+"/"
    switch role {
    case .card:
      let known=[string("portraitURL",game)]+[capsule,game.artworkURL].filter{portrait($0)}
      return unique(known+[base+"library_600x900.jpg",capsule,game.artworkURL,icon])
    case .banner:
      return unique([hero,base+"library_hero.jpg",banner,game.artworkURL,base+"header.jpg"].filter{$0 != icon})
    case .icon:return unique([icon,game.artworkURL,capsule,base+"header.jpg"])
    }
  }
  static func shouldAspectFit(imageSize:CGSize,role:Role)->Bool {
    guard imageSize.width>0,imageSize.height>0,imageSize.width.isFinite,imageSize.height.isFinite else{return true}
    if max(imageSize.width,imageSize.height)<=128{return true}
    switch role {
    case .icon:return true
    case .card:return imageSize.width/imageSize.height>1.15 || min(imageSize.width,imageSize.height)<128
    case .banner:return imageSize.width<640 || imageSize.width/imageSize.height<1.5
    }
  }
  static func imageRect(imageSize:CGSize,in bounds:CGRect,role:Role)->CGRect {
    guard imageSize.width>0,imageSize.height>0,imageSize.width.isFinite,imageSize.height.isFinite,
      bounds.width>0,bounds.height>0,bounds.width.isFinite,bounds.height.isFinite,bounds.minX.isFinite,bounds.minY.isFinite else{return .zero}
    let fit=shouldAspectFit(imageSize:imageSize,role:role)
    let scale=fit ? min(1,min(bounds.width/imageSize.width,bounds.height/imageSize.height)):max(bounds.width/imageSize.width,bounds.height/imageSize.height)
    let size=CGSize(width:imageSize.width*scale,height:imageSize.height*scale)
    return CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
  }
}
