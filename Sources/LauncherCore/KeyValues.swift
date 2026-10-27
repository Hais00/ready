import Foundation

/// Valve KeyValues parser for local library manifests. Does not evaluate directives or execute values.
public indirect enum KV: Equatable {
    case string(String), object([String:KV])
    public subscript(_ key:String)->KV? { if case .object(let o)=self{return o[key]};return nil }
    public var string:String? { if case .string(let s)=self{return s};return nil }
    public var object:[String:KV]? { if case .object(let o)=self{return o};return nil }
}
public enum KeyValues {
    public static func parse(_ text:String)throws->KV {
        let chars=Array(text);var i=0
        func token()throws->String? {
            while i<chars.count {
                if chars[i].isWhitespace{i+=1;continue}
                if chars[i]=="/",i+1<chars.count,chars[i+1]=="/" {while i<chars.count,chars[i] != "\n"{i+=1};continue};break
            }
            guard i<chars.count else{return nil}
            let c=chars[i];i+=1
            if c=="{" || c=="}"{return String(c)}
            var s=""
            if c=="\"" {
                while i<chars.count {let v=chars[i];i+=1;if v=="\""{return s};if v=="\\",i<chars.count {let e=chars[i];i+=1;s.append(e=="n" ? "\n":e=="t" ? "\t":e)}else{s.append(v)}}
                throw LauncherError.invalid("Stringa KeyValues incompleta")
            }
            s.append(c);while i<chars.count,!chars[i].isWhitespace,chars[i] != "{",chars[i] != "}" {s.append(chars[i]);i+=1};return s
        }
        func object(_ nested:Bool,_ depth:Int)throws->KV {
            guard depth<64 else{throw LauncherError.invalid("KeyValues troppo annidato")};var result=[String:KV]()
            while let key=try token() {
                if key=="}" {if nested{return .object(result)};throw LauncherError.invalid("Parentesi KeyValues inattesa")}
                guard key != "{",let value=try token(),value != "}" else{throw LauncherError.invalid("Valore KeyValues mancante")}
                result[key] = value=="{" ? try object(true,depth+1):.string(value)
            }
            if nested{throw LauncherError.invalid("Oggetto KeyValues incompleto")};return .object(result)
        }
        return try object(false,0)
    }
}
