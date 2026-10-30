// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct StorageLibraryRecord:Codable,Equatable,Identifiable {
  public let id:UUID
  public var name:String
  public let rootPath:String
  public let volumeUUID:String?
  public let deviceID:UInt64
  public let rootFileID:UInt64
  public let createdAt:Date
  public var isRemoved:Bool
}
public struct StorageInstallationRecord:Codable,Equatable,Identifiable {
  public enum State:String,Codable {case reserved,installed,incomplete}
  public let id:UUID,libraryID:UUID
  public let store:Store
  public let gameID:String
  public let platform:GamePlatform
  public let relativePath:String
  public let adopted:Bool
  public var state:State
  public let createdAt:Date
}
public struct StorageReservation:Codable,Equatable,Identifiable {
  public let id:UUID,installationID:UUID,libraryID:UUID
  public var requestedBytes:UInt64?
  public var remainingBytes:UInt64?
  public var jobID:String?
  public var ownerProfileID:UUID?=nil
  public let createdAt:Date
  public var requiresPlanning:Bool{requestedBytes==nil}
}
public struct StorageLibraryRegistry:Codable,Equatable {
  public var schema=1
  public var kind="ready-game-storage-v1"
  public var libraries=[StorageLibraryRecord]()
  public var defaultLibraryID:UUID?
  public var installations=[StorageInstallationRecord]()
  public var reservations=[StorageReservation]()
  public init(){}
}
public struct StorageLibraryStatus:Identifiable {
  public enum Availability:String {case online,offline,changedVolume,readOnly,unavailable}
  public let library:StorageLibraryRecord
  public var id:UUID{library.id}
  public let availability:Availability
  public let freeBytes:UInt64,totalBytes:UInt64,reservedBytes:UInt64
  public let isDefault:Bool
  public let unplannedReservations:Int
  public var availableBytes:UInt64{freeBytes>reservedBytes ? freeBytes-reservedBytes:0}
}
public enum StorageLibraryFailure:Error,LocalizedError {
  case unsafePath,invalidRegistry,invalidName,overlap,notFound,offline,changedVolume,readOnly,insufficientSpace,planningRequired,busy,conflict,io
  public var errorDescription:String?{
    switch self {
    case .unsafePath:return "Scegli una cartella locale assoluta senza collegamenti simbolici."
    case .invalidRegistry:return "Il registro delle cartelle giochi non è valido. I dati sono stati conservati."
    case .invalidName:return "Inserisci un nome valido per la cartella giochi."
    case .overlap:return "Questa cartella coincide o si sovrappone a una libreria già configurata."
    case .notFound:return "La cartella giochi o la prenotazione non è più configurata."
    case .offline:return "Il volume della cartella giochi non è collegato."
    case .changedVolume:return "La cartella ora appartiene a un volume o a una directory differente. Selezionala nuovamente."
    case .readOnly:return "La cartella giochi non è scrivibile."
    case .insufficientSpace:return "Spazio disponibile insufficiente, comprese le installazioni già prenotate sul volume."
    case .planningRequired:return "Calcola lo spazio necessario prima di creare l’installazione."
    case .busy:return "La cartella o il gioco ha già un’installazione in corso."
    case .conflict:return "Il percorso contiene già dati non registrati. Importali senza sostituirli."
    case .io:return "Impossibile aggiornare il registro delle cartelle giochi."
    }
  }
}
