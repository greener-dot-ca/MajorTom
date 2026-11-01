import CryptoKit
import Foundation
import Security

/// Facts derived from a server certificate for display and for the trust record.
///
/// Kept separate from ``SubjectPublicKeyFingerprint``, which extracts the one value TOFU
/// pins. These are the values a person compares against other tooling.
public enum CertificateDetails {
    /// Validity bounds from Security.framework's X.509 property dictionary.
    ///
    /// The values are CFAbsoluteTime numbers on current macOS releases, not `Date`
    /// instances. Accept both representations because the Core Foundation API leaves
    /// the bridged value type unspecified.
    public static func validityDates(certificateDER: Data) -> (
        notBefore: Date?,
        notAfter: Date?
    ) {
        #if !os(macOS)
        return derValidityDates(certificateDER: certificateDER)
        #else
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return (nil, nil)
        }
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] else {
            return (nil, nil)
        }

        func date(for key: CFString) -> Date? {
            guard let property = values[key] as? [CFString: Any],
                  let value = property[kSecPropertyKeyValue] else { return nil }
            if let date = value as? Date { return date }
            if let absoluteTime = value as? NSNumber {
                return Date(timeIntervalSinceReferenceDate: absoluteTime.doubleValue)
            }
            return nil
        }

        return (
            date(for: kSecOIDX509V1ValidityNotBefore),
            date(for: kSecOIDX509V1ValidityNotAfter)
        )
        #endif
    }

    /// Validity bounds read straight from the certificate's DER, for platforms without
    /// `SecCertificateCopyValues` (everything but macOS).
    static func derValidityDates(certificateDER: Data) -> (
        notBefore: Date?,
        notAfter: Date?
    ) {
        guard var fields = try? DERElement.tbsChildren(ofCertificate: certificateDER) else {
            return (nil, nil)
        }
        // The explicit [0] version is optional; then serial, signature, issuer, validity.
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count > 3,
              let times = try? fields[3].children(in: certificateDER),
              times.count == 2 else { return (nil, nil) }

        func date(_ element: DERElement) -> Date? {
            guard var text = String(data: certificateDER[element.contentRange], encoding: .ascii),
                  text.hasSuffix("Z") else { return nil }
            if element.tag == 0x17 {
                // UTCTime: RFC 5280 maps YY < 50 to 20YY and the rest to 19YY.
                guard let year = Int(text.prefix(2)) else { return nil }
                text = (year < 50 ? "20" : "19") + text
            } else if element.tag != 0x18 {
                return nil
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: text)
        }

        return (date(times[0]), date(times[1]))
    }

    /// Reads validity bounds from a stored PEM certificate. This keeps records written
    /// before validity extraction was fixed useful without requiring another connection.
    public static func validityDates(certificatePEM: String) -> (
        notBefore: Date?,
        notAfter: Date?
    ) {
        guard let certificateDER = der(certificatePEM: certificatePEM) else { return (nil, nil) }
        return validityDates(certificateDER: certificateDER)
    }

    /// Converts a PEM certificate retained in the trust store back to its DER bytes.
    public static func der(certificatePEM: String) -> Data? {
        let base64 = certificatePEM
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }

    /// SHA-256 of the entire certificate, lowercase hex.
    ///
    /// Deliberately *not* what trust is pinned to: a capsule that renews its certificate
    /// while keeping its key gets a new certificate digest but the same Subject Public
    /// Key Info fingerprint, and treating that as an identity change would cry wolf on
    /// every routine renewal. It is still worth showing, because it is what
    /// `openssl x509 -fingerprint -sha256` prints and therefore what someone verifying a
    /// capsule out of band will have in hand.
    public static func sha256(certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The certificate as PEM, so it can be pasted into `openssl` or a keychain.
    public static func pem(certificateDER: Data) -> String {
        let base64 = certificateDER.base64EncodedString()
        // PEM wraps at 64 characters per RFC 7468.
        var lines: [String] = ["-----BEGIN CERTIFICATE-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END CERTIFICATE-----")
        return lines.joined(separator: "\n")
    }
}
