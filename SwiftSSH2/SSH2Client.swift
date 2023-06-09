
///
/// List of possible errors thrown by the framework.
///
public enum SwiftSSH2Error: ErrorType {
  ///
  /// Thrown when `libssh2_session_init_ex` fails.
  ///
  case UnableToCreateUnderlyingLibSSH2Session
  
  ///
  /// Thrown whenever an operation is attempted without a valid `SSH2Session`.
  ///
  case UnableToProceedWithoutValidSSH2Session(String)
  
  ///
  /// Throw whenever `libssh2_sftp_init` fails.
  ///
  case SFTP2SessionError(String)
  
  ///
  /// Thrown when any host communication fails.
  ///   - Connect
  ///   - Discoverability
  ///
  case HostError(String)
  
  ///
  /// Thrown whenever an I/O operation fails.
  ///   - List directory contents
  ///   - Create directory
  ///   - Remove directory
  ///   - Resolve symlinks
  ///
  case IOError(String)
  
  ///
  /// Thrown whenever an authentication operation fails or lacks data to even attempt it.
  ///
  case AuthenticationFailed(String)
  
  ///
  /// Thrown whenever a retrieve operation fails.
  /// - Get banner
  /// - Retrieve authentication methods
  ///
  case RetrieveDataOperationError(String)
}

///
/// Manages *all* communication with the host/server.
///
public class SSH2Client {
  
  // MARK: Properties
  
  ///
  /// Current `SSH2Session` instance. (`nil` if not yet connected or failed to connect)
  ///
  public var session: SSH2Session? = nil
  
  private var hostaddr: String? = nil
  private var port: Int32
  private let username: String?
  private let password: String?
  
  /// Property that determines if the session was provided with `password`.
  /// If it was we assume the authorization to be password; if not then certificate.
  private var authorizeWithPassword: Bool {
    get {
      switch password {
        case .None: return false
        case .Some(_): return true
      }
    }
  }
  
  // MARK: Initializers
  ///
  /// Initializes an `SSHClient` instance with the parameters provided.
  ///
  /// - parameter host: The host/server address or name to which we'll be connecting.
  ///
  /// - parameter port: The `host` port to which we'll try to connect.
  ///
  /// - parameter username: The username we'll use to authenticate with the `host`.
  ///
  /// - parameter password: The password we'll use to authenticate with against the `host` (if any).
  ///
  /// - returns: Returns a fully initialized client ready to start connecting or `nil`
  /// if no valid host address/name was provided.
  ///
  public init?(host hostaddr: String, port: Int32 = 22, username: String? = nil, password: String? = nil) {
    // Assigning all properties to silence compiler warning
    self.hostaddr = hostaddr
    self.port = port
    self.username = username
    self.password = password
    
    // Cannot initialize without a host address or name
    guard hostaddr.characters.count > 0 else {
      println("• Cannot initialize without a host address or name")
      
      return nil
    }
  }

  // MARK: - Connection
  
  ///
  /// Start interacting with the provided `host`.
  ///
  /// - parameter hash: A `Fingerprint` hash specifying what type of hash will be used when
  /// getting the fingerprint back from the server.
  /// If none provided will default to `.MD5`
  ///
  /// - returns: A `Result` with a tuple of (SSH2Session, Fingerprint) for the current
  /// host if succeeds or `String` describing the current error.
  /// - Warning:
  ///   - throws `UnableToCreateUnderlyingLibSSH2Session`: When `libssh2_session_init` fails.
  ///   - throws `AuthenticationFailed`: When the `handshake` with the host fails.
  ///   - throws `HostError`:
  ///     + When unable to establish a socket with the host.
  ///     + When unable to discover address information for the server provided.
  ///
  public func startConnection(hash: Fingerprint.Hash=Fingerprint.Hash.MD5) throws -> (SSH2Session, Fingerprint) {
    let addrInfo = try self.discoverAddressInfoForHost()
    let sock = try self.connectToSocketUsing(addrInfo: addrInfo)
    
    // Initialize the libssh2 flow
    var rc = libssh2_init(0)
    
    // Create a session that will be used to interact with the server
    let cSession = libssh2_session_init_ex(nil, nil, nil, nil)
    session = SSH2Session(cSession: cSession)
    
    guard let oSession = self.session else {
      throw SwiftSSH2Error.UnableToCreateUnderlyingLibSSH2Session
    }
    
    // Set the session as blocking
    libssh2_session_set_blocking(oSession.cSession, 10)
    
    // Start the handshake with the server (exchanging banners, MAC layers, etc)
    repeat {
      rc = libssh2_session_handshake(oSession.cSession, sock)
    } while (rc == LIBSSH2_ERROR_EAGAIN)
    
    // Check if the handshake failed
    guard rc == 0 else {
      let errMsg = "Handshake failed: " + String.fromCString(strerror(errno))!
      println(errMsg)
      
      throw SwiftSSH2Error.AuthenticationFailed(errMsg)
    }
    
    // Grab the server fingerprint if possible
    let cFingerprint = libssh2_hostkey_hash(oSession.cSession, hash.rawValue)
    let fingerprint = Fingerprint.fingerprint(cFingerprint, hash: hash)
    println("• Fingerprint: \(fingerprint.fingerprint)\n")
    
    let tupleResult:(SSH2Session, Fingerprint) = (oSession, fingerprint)

    return tupleResult
  }
  
  /// Opens up a new `SFTP2 Session`.
  ///
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the banner.
  /// If `nil` a previously open internal session will be used or an error will be returned.
  ///
  /// - returns: An open `SFTPSession` authenticated with `self.session`.
  ///
  /// - Warning:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: If not a valid `SSH2Session` was found.
  ///   - throws `SFTP2SessionError`: If unabled to init an `SFTP` session
  public func openSFTPSession(session sess: SSH2Session?=nil) throws -> SFTPSession {
    /********************************************************
    * Parameters validation and local variables declarations
    *********************************************************/
    // - Session:
    let session: SSH2Session
    switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot retrieve banner.")
    }
    
    var sftp_session: SFTPSession
    repeat {
      sftp_session = SFTPSession(cSFTPSession:libssh2_sftp_init(session.cSession))
      
      let sftpStatus = libssh2_session_last_errno(session.cSession)
      guard sftp_session.cSFTPSession.hashValue != 0 || sftpStatus == LIBSSH2_ERROR_EAGAIN else {
        let errMsg = "SFTP2 init session failed: " + String.fromCString(strerror(errno))!
        println(errMsg)

        throw SwiftSSH2Error.SFTP2SessionError(errMsg)
      }
    } while (sftp_session.cSFTPSession.hashValue == 0)
    
    return sftp_session
  }
  
  
  // MARK: - Connection Settings
  
  /// Retrieves the remove banner from the server (if any).
  ///
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the banner.
  /// If `nil` a previously open internal session will be used or an error will be returned.
  ///
  /// - returns: The host's remote banner (if any) or an error if there's no valid/open `SSH2Session`.
  ///
  /// - Warning:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: When no valid `SSH2Session` was passed or found internally.
  ///   - throws `RetrieveDataOperationError`: When the host returns an invalid banner.
  public func remoteBanner(session sess: SSH2Session?=nil) throws -> String? {
    /********************************************************
    * Parameters validation and local variables declarations
    *********************************************************/
    // - Session:
    let session: SSH2Session
    switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot retrieve banner.")
    }
    
    // Get the banner from the host
    let banner = libssh2_session_banner_get(session.cSession)
    guard let bannrStr = String.fromCString(banner) else {
      throw SwiftSSH2Error.RetrieveDataOperationError("Unable to retrieve banner from host \(self.hostaddr!)")
    }

    println("• Remote host banner: \(bannrStr)")
    
    return bannrStr
  }
  
  
  // MARK: - Authentication
  
  /// Retrieve *all* supported authentication methods from the `host` for the provided `username`.
  ///
  /// - parameter username: The username that will be used to retrieve authentication methods for.
  /// If `nil` the framework will try to retrieve the `username` from the initialization.
  ///
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the banner.
  /// If `nil` a previously open internal session will be used or an error will be returned.
  ///
  /// - returns: A list of `String` name for the supported authentication methods for the provided `username`.
  /// 
  /// - Warning:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: When no valid `SSH2Session` was passed or found internally.
  ///   - throws `AuthenticationFailed`: When no valid `username` was passed or found internally.
  ///   - throws `RetrieveDataOperationError`: When unabled to check authentication methods for the host and username combination.
  public func supportedAuthenticationMethodsForUsername(username usr:String?=nil, session sess: SSH2Session?=nil) throws -> [String] {
    /********************************************************
    * Parameters validation and local variables declarations
    *********************************************************/
    // - Session:
    let session: SSH2Session
    switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot check authentication methods.")
    }
    
    // - Username:
    let username: String
    switch (usr, self.username) {
      case (.Some(let parameterUsername), _): username = parameterUsername
      case (_, .Some(let selfUsername)): username = selfUsername
      default: throw SwiftSSH2Error.AuthenticationFailed("Cannot check authentication methods without valid username")
    }
    
    // Reading the authentication methods from the session
    guard let methodsList:String = String.fromCString(libssh2_userauth_list(session.cSession, username, UInt32(username.characters.count))) else {
      throw SwiftSSH2Error.RetrieveDataOperationError("Failed to get authentication method for host \(self.hostaddr!)")
    }
    
    let methods = methodsList.componentsSeparatedByString(",")
    println("• Supported methods for host: \(methodsList)")
    
    return methods
  }
  
  /// Checks if the `host` supports the provided authentication `method` for the provided `username`.
  ///
  /// - parameter method: The name of the authentication method to check against the available methods on the host for the provided `username`.
  /// - parameter username: The username that will be used to retrieve authentication methods for.
  /// If `nil` the framework will try to retrieve the `username` from the initialization.
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the banner.
  /// If `nil` a previously open internal session will be used or an error will be returned.
  /// 
  /// - Warnings:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: When no valid `SSH2Session` was passed or found internally.
  ///   - throws `AuthenticationFailed`: When no valid `username` was passed or found internally.
  ///   - throws `RetrieveDataOperationError`: When unabled to check authentication methods for the host and username combination.
  public func supportsAuthenticationMethod(method: String, session sess: SSH2Session?=nil, username usr: String?=nil) throws -> Bool {
    /********************************************************
    * Parameters validation and local variables declarations
    *********************************************************/
    // - Session
    let session: SSH2Session
    switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot check authentication method: \(method)")
    }
    
    // - Username:
    let username: String
    switch (usr, self.username) {
      case (.Some(let parameterUsername), _): username = parameterUsername
      case (_, .Some(let selfUsername)): username = selfUsername
      default: throw SwiftSSH2Error.AuthenticationFailed("Cannot check authentication methods without valid username")
    }
   
    // We convert to lowercase to compare methods in same casing
    let lwrMethod = method.lowercaseString
    return try self.supportedAuthenticationMethodsForUsername(username: username, session: session).filter{$0.lowercaseString == lwrMethod}.count > 0
  }
  
  /// Authorize agains the provided `host` using `username` & `password`.
  ///
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the banner.
  /// If `nil` a previously open internal session will be used or an error will be returned.
  /// - parameter username: The username that will be used to authenticate with on the host.
  /// If `nil` the framework will try to retrieve the `username` from the initialization.
  /// - parameter password: The password that will be used to authenticate with on the host.
  /// If `nil` the framework will try to retrieve the `username` from the initialization.
  /// 
  /// - Warnings:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: When no valid `SSH2Session` was passed or found internally.
  ///   - throws `AuthenticationFailed`:
  ///     + When no valid `username` was passed or found internally.
  ///     + When remote host doesn't support `password` authentication for the provided `username`.
  ///     + When there's no match on the remote server for the `username` & `password` provided.
  public func authorizeWithCredentials(session sess: SSH2Session?=nil, username usr: String?=nil, password passw: String?=nil) throws -> Bool {
    /********************************************************
    * Parameters validation and local variables declarations
    *********************************************************/
    // - Session
    let session: SSH2Session
      switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot authorize")
    }
    
    // - Username:
    let username: String
    switch (usr, self.username) {
      case (.Some(let parameterUsername), _): username = parameterUsername
      case (_, .Some(let selfUsername)): username = selfUsername
      default: throw SwiftSSH2Error.AuthenticationFailed("Cannot check authentication methods without valid username")
    }
    
    // If there's a password present let's check if password authentication is supported
    // for the user.
    if passw != nil {
      let supportsPasswordAuthentication = try self.supportsAuthenticationMethod("password", session: session)
      guard supportsPasswordAuthentication else {
        throw SwiftSSH2Error.AuthenticationFailed("`password` authentication not supported for user: `\(username)` on remote host.")
      }
    }
    
    // TODO: Add support for other authentication types [Issue: https://github.com/esttorhe/SwiftSSH2/issues/1]
    // - Password:
    let password: String
    switch (passw, self.password) {
      case (.Some(let parameterPassword), _): password = parameterPassword
      case (_, .Some(let selfPassword)): password = selfPassword
      // Currently only supporting password authentication.
      default: throw SwiftSSH2Error.AuthenticationFailed("Cannot authorized without a valid username and password.")
    }
    
    var rc: Int32 = 0
    repeat {
      rc = libssh2_userauth_password_ex(session.cSession, username, UInt32(username.characters.count), password, UInt32(password.characters.count), nil)
    } while (rc == LIBSSH2_ERROR_EAGAIN)
    
    guard rc == 0 else {
      let errMsg = "Authentication Failed: " + String.fromCString(strerror(errno))!
      println(errMsg)
      
      throw SwiftSSH2Error.AuthenticationFailed(errMsg)
    }
    
    return true
  }
  
  
  // MARK: - Directories
  
  /// Create a directory at the specified `path`.
  ///
  /// - parameter path: The full path where we want to create the folder.
  ///
  /// - parameter createIntermediateDirectories: `Boolean` flag that specifies if we want to create the intermediate
  ///   directories or not.
  ///
  /// - parameter sftp_session: A valid `SFTP2Session` that will be used to create the directory.
  /// 
  /// - Warnings:
  ///   - throws `IOError`: When the directory creation fails.
  ///     + _If `createIntermediateDirectories` is set to true it will only `throw` on the last path component._
  public func createDirectoryAtPath(path: String, createIntermediateDirectories: Bool=false, sftp_session: SFTPSession) throws -> () {
    /********************************************************************************
    ** Temporarily removed parameter >> flags flagsStuct: FilePermission
    *********************************************************************************
    // Convert to string
    let strFlags = flagsStuct.flags
    
    guard let flags = Int(strFlags) else {
      let errMsg = "Remove directory failed: " + String.fromCString(strerror(errno))!
      println(errMsg)
      
      throw SwiftSSH2Error.IOError(errMsg)
    }
    */
    var result: Int32 = -1
    var err: SwiftSSH2Error? = nil
    let url = NSURL(string: path)!
    
    // Iterate while result is positive or LIBSSH2_ERROR_EAGAIN
    repeat {
      if !createIntermediateDirectories {
        // Try to create the directory
        result = libssh2_sftp_mkdir_ex(sftp_session.cSFTPSession, path, UInt32(path.characters.count),
          Int(LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH))
        guard result >= 0 else {
          let errMsg = "Create directory failed: " + String.fromCString(strerror(errno))!
          println(errMsg)
          
          throw SwiftSSH2Error.IOError(errMsg)
        }
        
        println("• Created directory at path: \(path)")
      } else { // Split the paths and try to create from «outer» to «inner».
        let _ = url.pathComponents!.reduce("") { combined, component -> String in
          let currentPath: NSURL
          if combined.characters.count > 0 {
            currentPath = NSURL(string: combined)!.URLByAppendingPathComponent(component)
          } else {
            currentPath = NSURL(string: component)!
          }
    
          do {
            try self.createDirectoryAtPath(currentPath.absoluteString, createIntermediateDirectories: false, sftp_session: sftp_session)
    
            return currentPath.absoluteString
          } catch {
            // Some of the intermediate folders might fail.
            let errMsg = "[\(result)] Create directory failed: " + String.fromCString(strerror(errno))!
            println(errMsg)
            
            /**************************************************************************
            // Sadly there's no way for us to know if it failed due to something 
            // else other than the directory already exists.
            // We have to take the positive approach and assume it failed due to that.
            // Only check for the last path component
            **************************************************************************/
            if component == url.pathComponents!.last {
              err = SwiftSSH2Error.IOError(errMsg)
            }
          }
          
          return currentPath.absoluteString
        }
      }
    } while (result > 0 || result == LIBSSH2_ERROR_EAGAIN)
    
    if let error = err {
      throw error
    }
  }
  
  /// Deletes the directory at `path`.
  ///
  /// - parameter path: The full path of the folder to be deleted.
  ///
  /// - parameter sftp_session: A valid `SFTP2Session` that will be used to delete the directory.
  /// 
  /// - Warnings:
  ///   - throws `IOError`: When the directory deletion fails.
  public func removeDirectoryAtPath(path: String, sftp_session: SFTPSession) throws -> String {
    guard libssh2_sftp_rmdir_ex(sftp_session.cSFTPSession, path, UInt32(path.characters.count)) == 0 else {
      let errMsg = "Remove directory failed: " + String.fromCString(strerror(errno))!
      println(errMsg)
      
      throw SwiftSSH2Error.IOError(errMsg)
    }
    
    return "Successfully deleted directory \(path)"
  }

  /// Lists all the items (files & folders) of the directory at `path`.
  ///
  /// - parameter session: A valid `SSH2Session` that will be used to retrieve the items.
  ///   If `nil` a previously open internal session will be used or an error will be returned.
  ///
  /// - parameter path: The full path of the folder we want to inspect.
  ///
  /// - parameter sftp_session: A valid `SFTP2Session` that will be used to create the directory.
  /// 
  /// - Warnings:
  ///   - throws `UnableToProceedWithoutValidSSH2Session`: When no valid `SSH2Session` was found.
  ///   - throws `IOError`:
  ///     + When unable to open the directory specified on `path`.
  ///     + When unable to read the directory specified on `path`.
  public func listItemsOnPath(path sftppath: String, sftp_session: SFTPSession, session sess: SSH2Session? = nil) throws -> [File] {
    // Support injecting an `SSH2Session` for testing purposes
    let session: SSH2Session
    switch (sess, self.session) {
      case (.Some(let parameterSession), _): session = parameterSession
      case (_, .Some(let selfSession)): session = selfSession
      default: throw SwiftSSH2Error.UnableToProceedWithoutValidSSH2Session("Cannot list items for path: \(sftppath).")
    }
    
    /* Request a dir listing via SFTP */
    var rc: Int32 = 0
    var sftp_handle: SFTPFileHandle
    repeat {
      sftp_handle = SFTPFileHandle(fileHandle: libssh2_sftp_open_ex(sftp_session.cSFTPSession, sftppath, UInt32(sftppath.characters.count), 0, 0, LIBSSH2_SFTP_OPENDIR))
      sftp_handle.isDirectory = true
      
      let sftpHandleStatus = libssh2_session_last_errno(session.cSession) != LIBSSH2_ERROR_EAGAIN
      guard (sftp_handle.cFileHandle.hashValue != 0 || !sftpHandleStatus) else {
        let errMsg = "SFTP2 open directory failed: " + String.fromCString(strerror(errno))!
        println(errMsg)
        
        throw SwiftSSH2Error.IOError(errMsg)
      }
    } while (sftp_handle.cFileHandle.hashValue == 0)
    
    /* loop until we can't read any more data to the buffer */
    var result = [File]()
    repeat {
      // Local variables declaration
      let buffSize = 512
      let attrs = UnsafeMutablePointer<LIBSSH2_SFTP_ATTRIBUTES>.alloc(1)
      let buffer = UnsafeMutablePointer<Int8>.alloc(buffSize)
      let longe = UnsafeMutablePointer<Int8>.alloc(buffSize)
      
      defer {
        longe.dealloc(buffSize)
        buffer.dealloc(buffSize)
        attrs.dealloc(1)
      }
    
      repeat {
        rc = libssh2_sftp_readdir_ex(sftp_handle.cFileHandle, buffer, buffSize, longe, buffSize, attrs)
      } while (rc == LIBSSH2_ERROR_EAGAIN)
      
      // rc is the length of the file name in the mem buffer
      switch rc {
        case (_) where rc == LIBSSH2_ERROR_EAGAIN: /* Blocking */
          println("• \(stderr)Blocking")
        case (_) where rc > 0: /* Successfully read to the buffer */
          if let file = File(buffer: buffer, fileAttributes: attrs.memory, longentry: longe) {
            result.append(file)
            println("\t\t\t• \(file.type) •")
          }
        case (_) where rc < 0: /* There was an error */
          let errMsg = "SFTP2 read directory failed: " + String.fromCString(strerror(errno))!
          println(errMsg)
          
          throw SwiftSSH2Error.IOError(sftppath)
        default: return result /* We finished reading the directory */
      }
    } while (rc > 0)

    // Added to silence compiler warning 
    throw SwiftSSH2Error.IOError("Unable to list items at path \(sftppath)")
  }
  
  public func currentDirectoryPath(sftp_session sftp_session: SFTPSession) throws -> String {
    return try self.resolveSymlink(sftp_session, path: ".", complex: true)
  }
  
  // MARK: - Internal Helpers
  // MARK: Sockets
  
  /// 
  /// Using the `host` from initialization call `getaddrinfo` to retrieve information
  /// about the host/address, protocol type, etc.
  ///
  /// - returns: An `addrinfo` structure containing the connection information for the 
  /// provided `host`.
  ///
  /// - Warning:
  ///   - throws `HostError`:
  ///     + When `getaddrinfo` fails to retrieve any data.
  ///     + When the «retrieve» data is empty (unable to read data for the host).
  ///
  internal func discoverAddressInfoForHost() throws -> addrinfo {
    // Local variables initialization
    guard let hostaddr = self.hostaddr else {
      throw SwiftSSH2Error.HostError("Host address/name not provided.")
    }
    
    /** ========================================================================
    * This is commented out until a bug in `Swift` gets fixed that prevents this
    * method signature to be called with the correct parameters.
    * Radar link here: http://openradar.me/21275861
    * ========================================================================*/
    // Get address info
    /*******************************************************************************
    let host:CFHost! = CFHostCreateWithName(kCFAllocatorDefault, hostaddr).takeRetainedValue()
    let error = UnsafeMutablePointer<CFStreamError>.alloc(1)
    if CFHostStartInfoResolution(host, CFHostInfoType.Addresses, error) {
      let hbr = UnsafeMutablePointer<Boolean>()
      addresses = CFHostGetAddressing(host, hbr)
      
      host.release()
    }
    *******************************************************************************/
    
    // Let's configure the base hints structure that we want to use to
    // «discover» the server info matching.
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    let unsafePointer = UnsafeMutablePointer<addrinfo>.alloc(1)
    unsafePointer.initialize(hints)
    let hintsPointer = UnsafePointer<addrinfo>(unsafePointer)
    let servInfo = UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>>.alloc(sizeofValue(UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>>))
    let addrInfo = getaddrinfo(hostaddr, String(port), hintsPointer, servInfo)
    
    defer {
      unsafePointer.dealloc(1)
      servInfo.dealloc(sizeofValue(UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>>))
    }
    
    guard addrInfo == 0 else {
      let errMsg = ("Get Address Info Failed: " + String.fromCString(strerror(errno))!)
      println(errMsg)
      
      throw SwiftSSH2Error.HostError(errMsg)
    }
    
    guard servInfo.hashValue != 0 && servInfo.memory.hashValue != 0 else {
      throw SwiftSSH2Error.HostError("Unable to discover server information for host.")
    }
    
    return servInfo.memory.memory
  }
  
  /// 
  /// Connect/open a socket using the provided `addrinfo` as guide.
  ///
  /// - parameter addrInfo: The `addrinfo` structure containing all the information
  /// required to connect to the `host`.
  ///
  /// - returns: A fully initialiazed and «open» `libssh2_socket_t` to the `host`.
  ///
  /// - Warning:
  ///   - throws `HostError`: When unable to establish a connection with the `host` using
  ///   the provided `addrInfo` structure.
  ///
  internal func connectToSocketUsing(addrInfo addrInfo: addrinfo) throws -> libssh2_socket_t {
    // loop through all the results and connect to the first we can
    var p:addrinfo = addrInfo
    var sock: libssh2_socket_t = -1
    
    // TODO: Rewrite this block in a clearer/«prettier» way. Currently looks like a «hack» [Issue: https://github.com/esttorhe/SwiftSSH2/issues/2]
    // Iterate through the list of addrinfo
    while true {
      // Let's try to create a socket with the discovered info
      let sockfd = socket(p.ai_family, p.ai_socktype, p.ai_protocol)
      if (sockfd == -1) {
        println("• socket failed: " + String.fromCString(strerror(errno))!)
       
        // Move to the next possible addrinfo
        if p.ai_next.hashValue != 0 { p = p.ai_next.memory; continue }
        break
      }
      
      // Let's try to connect to the new socket
      let connectStatus = connect(sockfd, address: p.ai_addr.memory)
      if (connectStatus == -1) {
        close(sockfd)
        println("• connect failed: " + String.fromCString(strerror(errno))!)
        
        // Move to the next possible addrinfo
        if p.ai_next.hashValue != 0 { p = p.ai_next.memory; continue }
        break
      }
      
      sock = sockfd
      break
    }
    
    // No valid socket was found
    guard sock != -1 else {
      throw SwiftSSH2Error.HostError("Unable to open connection to server.")
    }
    
    return sock
  }
  
  // MARK: Paths
  
  ///
  /// Resolves the symbolic link specified at `path`.
  ///
  /// - parameter path: The full path of the symlink we want to resolve.
  ///
  /// - parameter sftp_session: A valid `SFTP2Session` that will be used to create the directory.
  ///
  /// - returns: The fully «expanded» path for the symlink at `path`.
  ///
  /// - Warning:
  ///   - throws `IOError`:
  ///     + When unable to resolve the symlink of the path from the host.
  ///     + When unable to read the «resolved» path name.
  ///
  public func destinationOfSimbolicLinkAtPath(path: String, sftp_session: SFTPSession) throws -> String {
    return try self.resolveSymlink(sftp_session, path: path, complex: false)
  }
  
  ///
  /// Resolves the symbolic link specified at `path`.
  ///
  /// - parameter path: The full path of the symlink we want to resolve.
  ///
  /// - parameter sftp_session: A valid `SFTP2Session` that will be used to create the directory.
  ///
  /// - returns: The fully «expanded» path for the symlink at `path`.
  ///
  /// - Warning:
  ///   - throws `IOError`:
  ///     + When unable to resolve the symlink of the path from the host.
  ///     + When unable to read the «resolved» path name.
  ///
  internal func resolveSymlink(sftp_session: SFTPSession, path: String, complex: Bool=true) throws -> String {
    let buffer: UnsafeMutablePointer<Int8> = UnsafeMutablePointer<Int8>.alloc(1)
    var pathLength: Int32 = 0
    var bufferLength: UInt32 = 256
    
    defer {
      buffer.dealloc(1)
    }
    
    repeat {
      pathLength = libssh2_sftp_symlink_ex(sftp_session.cSFTPSession, path, UInt32(path.characters.count), buffer, bufferLength, complex ? LIBSSH2_SFTP_REALPATH : LIBSSH2_SFTP_READLINK)
      bufferLength *= 2 // grow exponentially so don't get bogged down too long
    } while(pathLength == LIBSSH2_ERROR_BUFFER_TOO_SMALL)
    
    guard pathLength >= 0 else {
      let errMsg = "Resolving symlink failed: " + String.fromCString(strerror(errno))!
      println(errMsg)

      throw SwiftSSH2Error.IOError(errMsg)
    }

    guard let pathName = String.fromCString(buffer) else {
      throw SwiftSSH2Error.IOError("Cannot retrieve path name for path: \(path)")
    }
    
    println("• Current Path: \(pathName)")
    
    return pathName
  }
}
