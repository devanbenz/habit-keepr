import Cocoa
import SwiftUI
import PostgresNIO

class PostgresService {
    static let shared = PostgresService()
    private var client: PostgresClient?
    private let logger = Logger(label: "postgres.timer")
    private var runTask: Task<Void, Error>?
    
    func connect() async throws {
        print("PostgresService: Starting connection")
        let host = AppSettings.shared.postgresHost
        let port = AppSettings.shared.postgresPort
        let username = AppSettings.shared.postgresUser
        let password = AppSettings.shared.postgresPass
        let database = AppSettings.shared.postgresDB
        
        print("PostgresService: Creating configuration with host: \(host), port: \(port), user: \(username), db: \(database)")
        
        let config = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
        
        print("PostgresService: Creating client")
        client = PostgresClient(configuration: config)
        
        runTask = Task {
            await client?.run()
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        print("PostgresService: Testing connection")
        if try await testConnection() {
            print("PostgresService: Connection succeeded test")
        } else {
            print("PostgresService: Connection failed test")
            throw PostgresError.connectionError(message: "Failed to establish connection")
        }
        
        print("PostgresService: Creating table if needed")
        try await createTableIfNeeded()
        print("PostgresService: Connection completed successfully")
    }
    
    func testConnection() async throws -> Bool {
        print("PostgresService: Testing connection")
        guard let client = client else {
            print("PostgresService: No client available")
            return false
        }
        
        do {
            print("PostgresService: Executing test query")
            try await client.query("SELECT 1;", logger: logger)
            print("PostgresService: Test query successful")
            return true
        } catch {
            print("PostgresService: Test query failed with error: \(error)")
            return false
        }
    }
    
    private func createTableIfNeeded() async throws {
        print("PostgresService: Starting table creation check")
        guard let client = client else {
            print("PostgresService: No client available for table creation")
            throw PostgresError.connectionError(message: "No client connection")
        }
        
        try await client.query("""
            CREATE TABLE IF NOT EXISTS habit_tracking (
                task_type TEXT NOT NULL,
                task_name TEXT NOT NULL,
                description TEXT,
                mins INTEGER,
                begin_time TIMESTAMP NOT NULL,
                end_time TIMESTAMP,
                PRIMARY KEY (task_type, task_name, begin_time)
            );
            """, logger: self.logger)
        print("PostgresService: Table creation/check successful")
    }
    
    func insertTimerEntry(_ entry: TimerEntry) async throws {
        guard let client = client else {
            logger.error("No PostgreSQL client available")
            throw PostgresError.connectionError(message: "No client connection")
        }
        
        let entryType = switch entry.type {
        case .Task: "task"
        case .Break: "break"
        case .Recreation: "recreation"
        case.Hobby: "hobby"
        }
        
        do {
            logger.info("Attempting to insert timer entry")
            try await client.query("""
                INSERT INTO habit_tracking (task_type, task_name, description, mins, begin_time, end_time)
                VALUES (\(entryType), \(entry.name), \(entry.description), \(entry.duration), \(entry.startTime), \(entry.endTime));
            """)
            logger.info("Successfully inserted timer entry")
        } catch {
            logger.error("Failed to insert timer entry: \(String(reflecting: error))")
            throw PostgresError.insertionError(message: String(reflecting: error))
        }
    }
    
    deinit {
        runTask?.cancel()
    }
}

enum PostgresError: Error {
    case connectionError(message: String)
    case insertionError(message: String)
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @AppStorage("postgresUser") var postgresUser: String = ""
    @AppStorage("postgesPass") var postgresPass: String = ""
    @AppStorage("postgesHost") var postgresHost: String = ""
    @AppStorage("postgesPort") var postgresPort: Int = 0
    @AppStorage("postgesDB") var postgresDB: String = ""
}

enum TimerType {
    case Task
    case Break
    case Recreation
    case Hobby
}

struct TimerEntry {
    let id = UUID()
    let type: TimerType
    let name: String
    let description: String
    var duration: Int
    let startTime: Date
    var endTime: Date
    
    init(type: TimerType, name: String, description: String, startTime: Date = Date()) {
        self.type = type
        self.name = name
        self.description = description
        self.startTime = startTime
        self.duration = 0
        self.endTime = startTime
    }
}

// Enhanced Timer Manager with secure file writing
class TimerManager: ObservableObject {
    @Published var currentTimer: TimerEntry?
    private var timer: Timer?
    private let postgresService = PostgresService.shared
        
    func startTimer(type: TimerType, name: String, description: String) {
        stopTimer()
        
        currentTimer = TimerEntry(type: type, name: name, description: description)
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard var timer = self?.currentTimer else { return }
            timer.duration = Int(Date().timeIntervalSince(timer.startTime) / 60)
            timer.endTime = Date()
            self?.currentTimer = timer
        }
    }
    
    func stopTimer() {
        timer?.invalidate()
        
        guard let completedTimer = currentTimer else { return }
        
        Task {
            do {
                try await postgresService.insertTimerEntry(completedTimer)
            } catch {
                print("Error inserting into Postgres: \(error)")
            }
        }
        
        currentTimer = nil
    }
    
    struct SettingsView: View {
        @ObservedObject var settings = AppSettings.shared
        private let postgresService = PostgresService.shared
        @Environment(\.presentationMode) var presentationMode
        
        @State private var isConnecting = false
        @State private var showError = false
        @State private var errorMessage = ""
        
        // Temporary state to hold values until save
        @State private var tempUser: String = ""
        @State private var tempPass: String = ""
        @State private var tempHost: String = ""
        @State private var tempPort: Int = 5432
        @State private var tempDB: String = ""
        
        init() {
            _tempUser = State(initialValue: settings.postgresUser)
            _tempPass = State(initialValue: settings.postgresPass)
            _tempHost = State(initialValue: settings.postgresHost)
            _tempPort = State(initialValue: settings.postgresPort)
            _tempDB = State(initialValue: settings.postgresDB)
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 15) {
                Text("Database Settings")
                    .font(.title)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 10)
                
                Group {
                    HStack {
                        Text("Username:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("username", text: $tempUser)
                            .frame(width: 200)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    HStack {
                        Text("Password:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("password", text: $tempPass)
                            .frame(width: 200)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    HStack {
                        Text("Host:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("localhost", text: $tempHost)
                            .frame(width: 200)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    HStack {
                        Text("Port:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("5432", value: $tempPort, format: .number)
                            .frame(width: 200)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    HStack {
                        Text("Database:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("database", text: $tempDB)
                            .frame(width: 200)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                
                HStack {
                    Spacer()
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Button(action: {
                        print("Save button pressed")
                        isConnecting = true
                        Task {
                            do {
                                print("Starting connection process")
                                settings.postgresUser = tempUser
                                settings.postgresPass = tempPass
                                settings.postgresHost = tempHost
                                settings.postgresPort = tempPort
                                settings.postgresDB = tempDB
                                
                                print("Calling connect()")
                                try await postgresService.connect()
                                print("Connected")
                                isConnecting = false
                            } catch {
                                print("Error occurred: \(error)")
                                await MainActor.run {
                                    isConnecting = false
                                    errorMessage = error.localizedDescription
                                    showError = true
                                }
                            }
                        }
                    }) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isConnecting)
                    .keyboardShortcut(.defaultAction)
                }
                .alert("Connection Error", isPresented: $showError) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(errorMessage)
                }
                .padding(.top, 20)
                .padding(.trailing, 10)
            }
        }
    }
    
    struct TimerTrackerView: View {
        @StateObject private var timerManager = TimerManager()
        @State private var timerType: TimerType = .Task
        @State private var timerDescription = ""
        @State private var taskName = ""
        @State private var showSettings = false
        
        var body: some View {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.plain)
                }
                
                Text(formatTimer())
                    .font(.largeTitle)
                    .padding()
                
                Picker("Timer Type", selection: $timerType) {
                    Text("Task").tag(TimerType.Task)
                    Text("Break").tag(TimerType.Break)
                    Text("Recreation").tag(TimerType.Recreation)
                    Text("Hobby").tag(TimerType.Hobby)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
                
                TextField("Task Name", text: $taskName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                TextField("Description", text: $timerDescription)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                HStack {
                    Button("Start Timer") {
                        timerManager.startTimer(type: timerType, name: taskName, description: timerDescription)
                    }
                    .disabled(timerManager.currentTimer != nil)
                    
                    Button("Stop Timer") {
                        timerManager.stopTimer()
                        
                        timerType = .Task
                        taskName = ""
                        timerDescription = ""
                    }
                    .disabled(timerManager.currentTimer == nil)
                }
            }
            .padding()
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .frame(width: 450, height: 400)
            }
            .frame(width: 300, height: 250)
        }
        
        func formatTimer() -> String {
            guard let timer = timerManager.currentTimer else {
                return "00:00:00"
            }
            
            let hours = timer.duration / 60
            let minutes = timer.duration % 60
            let seconds = Int(Date().timeIntervalSince(timer.startTime)) % 60
            
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }
    
    // Menu Bar Extra
    class AppDelegate: NSObject, NSApplicationDelegate {
        var statusItem: NSStatusItem!
        var popover: NSPopover!
        
        func applicationDidFinishLaunching(_ aNotification: Notification) {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timer")
                button.action = #selector(togglePopover)
            }
            
            popover = NSPopover()
            popover.contentViewController = NSHostingController(rootView: TimerTrackerView())
            popover.behavior = .transient
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(popoverWillClose),
                name: NSPopover.willCloseNotification,
                object: nil
            )
        }
        
        @objc func popoverWillClose(_ notification: Notification) {
            // TODO? Maybe cleanup popup on close
        }
        
        @objc func togglePopover() {
            if let button = statusItem.button {
                if popover.isShown {
                    popover.performClose(nil)
                } else {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
    }
    
    @main
    struct TimerTrackerApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
        
        var body: some Scene {
            WindowGroup {}
        }
    }
}
