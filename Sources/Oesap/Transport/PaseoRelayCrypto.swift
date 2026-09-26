import Foundation

/// Paseo's relay encryption: NaCl box.before + box.after, nonce || ciphertext.
/// The C implementation is the unmodified TweetNaCl 20140427 reference.
struct PaseoRelayCrypto {
  private let publicKey: [UInt8]
  private let sharedKey: [UInt8]

  var publicKeyBase64: String { Data(publicKey).base64EncodedString() }

  init(daemonPublicKeyBase64: String) throws {
    let daemonKey = try Self.validatePublicKey(daemonPublicKeyBase64)
    var ourPublicKey = [UInt8](repeating: 0, count: 32)
    var shared = [UInt8](repeating: 0, count: 32)
    let code = daemonKey.withUnsafeBufferPointer { daemonBuffer in
      ourPublicKey.withUnsafeMutableBufferPointer { publicBuffer in
        shared.withUnsafeMutableBufferPointer { sharedBuffer in
          paseo_nacl_client_session(
            daemonBuffer.baseAddress, publicBuffer.baseAddress,
            sharedBuffer.baseAddress)
        }
      }
    }
    guard code == 0 else { throw PaseoConnectionError.invalidDaemonKey }
    publicKey = ourPublicKey
    sharedKey = shared
  }

  /// Fixed secret is for upstream interoperability vectors in the offline test suite.
  init(daemonPublicKeyBase64: String, secretKey: [UInt8]) throws {
    let daemonKey = try Self.validatePublicKey(daemonPublicKeyBase64)
    guard secretKey.count == 32 else { throw PaseoConnectionError.encryptionFailed }
    var ourPublicKey = [UInt8](repeating: 0, count: 32)
    let generated = secretKey.withUnsafeBufferPointer { secretBuffer in
      ourPublicKey.withUnsafeMutableBufferPointer { publicBuffer in
        paseo_nacl_public(secretBuffer.baseAddress, publicBuffer.baseAddress)
      }
    }
    guard generated == 0 else { throw PaseoConnectionError.encryptionFailed }
    var shared = [UInt8](repeating: 0, count: 32)
    let derived = secretKey.withUnsafeBufferPointer { secretBuffer in
      daemonKey.withUnsafeBufferPointer { daemonBuffer in
        shared.withUnsafeMutableBufferPointer { sharedBuffer in
          paseo_nacl_derive(
            secretBuffer.baseAddress, daemonBuffer.baseAddress,
            sharedBuffer.baseAddress)
        }
      }
    }
    guard derived == 0 else { throw PaseoConnectionError.invalidDaemonKey }
    publicKey = ourPublicKey
    sharedKey = shared
  }

  static func validatePublicKey(_ encoded: String) throws -> [UInt8] {
    guard encoded.count == 44, encoded.last == "=",
      let data = Data(base64Encoded: encoded), data.count == 32,
      data.base64EncodedString() == encoded
    else {
      throw PaseoConnectionError.invalidDaemonKey
    }
    return Array(data)
  }

  func seal(_ plaintext: Data) throws -> Data {
    var nonce = [UInt8](repeating: 0, count: 24)
    guard
      nonce.withUnsafeMutableBufferPointer({
        paseo_nacl_random($0.baseAddress, $0.count)
      }) == 0
    else { throw PaseoConnectionError.encryptionFailed }
    return try seal(plaintext, nonce: nonce)
  }

  func seal(_ plaintext: Data, nonce: [UInt8]) throws -> Data {
    guard nonce.count == 24 else { throw PaseoConnectionError.encryptionFailed }
    var ciphertext = [UInt8](repeating: 0, count: plaintext.count + 16)
    let code = sharedKey.withUnsafeBufferPointer { shared in
      nonce.withUnsafeBufferPointer { nonceBytes in
        plaintext.withUnsafeBytes { plain in
          ciphertext.withUnsafeMutableBufferPointer { cipher in
            paseo_nacl_encrypt(
              shared.baseAddress, nonceBytes.baseAddress,
              plain.bindMemory(to: UInt8.self).baseAddress,
              plaintext.count, cipher.baseAddress)
          }
        }
      }
    }
    guard code == 0 else { throw PaseoConnectionError.encryptionFailed }
    return Data(nonce + ciphertext)
  }

  func open(_ bundle: Data) throws -> Data {
    guard bundle.count >= 40 else { throw PaseoConnectionError.malformedFrame }
    let nonce = Array(bundle.prefix(24))
    let ciphertext = Array(bundle.dropFirst(24))
    var plaintext = [UInt8](repeating: 0, count: ciphertext.count - 16)
    let code = sharedKey.withUnsafeBufferPointer { shared in
      nonce.withUnsafeBufferPointer { nonceBytes in
        ciphertext.withUnsafeBufferPointer { cipher in
          plaintext.withUnsafeMutableBufferPointer { plain in
            paseo_nacl_decrypt(
              shared.baseAddress, nonceBytes.baseAddress,
              cipher.baseAddress, ciphertext.count,
              plain.baseAddress)
          }
        }
      }
    }
    guard code == 0 else { throw PaseoConnectionError.encryptionFailed }
    return Data(plaintext)
  }
}
