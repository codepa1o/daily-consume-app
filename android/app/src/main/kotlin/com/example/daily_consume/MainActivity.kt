package com.example.daily_consume

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var retainedUpdateChannel: MethodChannel
    private var pendingNotificationPermission: MethodChannel.Result? = null
    private var pendingSkillAgentFileResult: MethodChannel.Result? = null
    private var pendingResearchDirectoryResult: MethodChannel.Result? = null
    private val researchPdfWriters = ConcurrentHashMap<String, ResearchPdfWriter>()

    private data class ResearchPdfWriter(
        val name: String,
        val temporaryFile: File?,
        val temporaryUri: Uri?,
        val treeUri: Uri?,
        val output: OutputStream,
        var size: Long = 0,
    )

    companion object {
        var updateChannel: WeakReference<MethodChannel>? = null
        private const val notificationPermissionRequest = 1333
        private const val skillAgentFileRequest = 1341
        private const val researchDirectoryRequest = 1342
        private const val skillAgentMaxFileBytes = 10 * 1024 * 1024
        private val researchPdfIo = Executors.newSingleThreadExecutor()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/updates")
        retainedUpdateChannel = channel
        updateChannel = WeakReference(channel)
        PomodoroAlert.ensureNotificationChannel(this)
        channel.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("updates", MODE_PRIVATE)
            when (call.method) {
                "state" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(mapOf(
                        "packageName" to packageName,
                        "versionCode" to versionCode(info),
                        "versionName" to info.versionName,
                        "cacheDirectory" to cacheDir.absolutePath,
                        "seenVersion" to prefs.getLong("seenVersion", 0),
                        "installError" to prefs.getBoolean("installError", false)
                    ))
                    prefs.edit().remove("installError").apply()
                }
                "markSeen" -> {
                    prefs.edit().putLong("seenVersion", (call.arguments as Number).toLong()).apply()
                    result.success(null)
                }
                "canInstall" -> result.success(canInstall())
                "openInstallSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("SETTINGS", "请在系统设置中允许本应用安装更新", null)
                    }
                }
                "install" -> {
                    if (!canInstall()) {
                        result.success("permissionRequired")
                    } else {
                        val path = call.argument<String>("path")
                        val expected = call.argument<Number>("versionCode")?.toLong()
                        // APK parsing, signature checks and copying run off the UI thread.
                        Thread {
                            try {
                                install(File(requireNotNull(path)), requireNotNull(expected))
                                runOnUiThread { result.success("started") }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("INSTALL", "无法安装更新，请确认安装包版本、签名和剩余空间", null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/pomodoro")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasNotificationPermission" -> result.success(hasNotificationPermission())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "openNotificationSettings" -> openNotificationSettings(result)
                    "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
                    "openExactAlarmSettings" -> openExactAlarmSettings(result)
                    "scheduleReminder" -> schedulePomodoroReminder(call, result)
                    "cancelReminder" -> {
                        cancelPomodoroReminder()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/travel_exports")
            .setMethodCallHandler { call, result ->
                if (call.method == "shareFiles") {
                    shareTravelFiles(call, result)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/research_files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "directory" -> result.success(researchDirectoryInfo())
                    "chooseDirectory" -> chooseResearchDirectory(result)
                    "useDefaultDirectory" -> {
                        getSharedPreferences("research_papers", MODE_PRIVATE).edit()
                            .remove("treeUri").apply()
                        result.success(researchDirectoryInfo())
                    }
                    "listPapers" -> listResearchPapers(result)
                    "beginPdf" -> beginResearchPdf(call, result)
                    "writePdfChunk" -> writeResearchPdfChunk(call, result)
                    "finishPdf" -> finishResearchPdf(call.arguments as? String, result)
                    "abortPdf" -> abortResearchPdf(call.arguments as? String, result)
                    "openPdf" -> openResearchPdf(call.arguments as? String, result)
                    "openUrl" -> openSkillAgentUrl(call.arguments as? String, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/skill_agent_files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDocument" -> pickSkillAgentDocument(result)
                    "openUrl" -> openSkillAgentUrl(call.arguments as? String, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun openSkillAgentUrl(value: String?, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(requireNotNull(value))
            require(uri.scheme == "https" || uri.scheme == "http")
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            result.success(null)
        } catch (_: Exception) {
            result.error("OPEN_URL", "无法打开该链接", null)
        }
    }

    private fun researchTreeUri(): Uri? = getSharedPreferences("research_papers", MODE_PRIVATE)
        .getString("treeUri", null)?.let(Uri::parse)

    private fun researchDefaultDirectory(): File =
        File(filesDir, "research_papers").apply { mkdirs() }

    private fun researchDirectoryInfo(): Map<String, Any> {
        val treeUri = researchTreeUri() ?: return mapOf(
            "label" to "本地文献（应用目录）",
            "custom" to false,
        )
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
        val label = try {
            contentResolver.query(
                documentUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
            }
        } catch (_: Exception) {
            null
        } ?: treeId.substringAfter(':').ifBlank { "所选文件夹" }
        return mapOf("label" to label, "custom" to true)
    }

    private fun chooseResearchDirectory(result: MethodChannel.Result) {
        if (pendingResearchDirectoryResult != null) {
            result.error("PICKER_BUSY", "已有文件夹选择窗口打开", null)
            return
        }
        try {
            pendingResearchDirectoryResult = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                )
            }
            startActivityForResult(intent, researchDirectoryRequest)
        } catch (_: Exception) {
            pendingResearchDirectoryResult = null
            result.error("PICKER", "无法打开系统文件夹选择器", null)
        }
    }

    private fun safeResearchFilename(value: String?): String {
        val cleaned = (value ?: "论文.pdf")
            .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
            .trim()
            .trim('.')
            .take(180)
        val name = if (cleaned.isBlank()) "论文.pdf" else cleaned
        require(name.lowercase().endsWith(".pdf"))
        return name
    }

    private fun findResearchDocument(treeUri: Uri, name: String): Uri? {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeId)
        return contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                if (idColumn >= 0 && nameColumn >= 0 && cursor.getString(nameColumn) == name) {
                    return@use DocumentsContract.buildDocumentUriUsingTree(
                        treeUri, cursor.getString(idColumn)
                    )
                }
            }
            null
        }
    }

    private fun availableResearchFilename(name: String, treeUri: Uri?): String {
        fun exists(candidate: String): Boolean =
            researchPdfWriters.values.any { it.name == candidate } ||
                if (treeUri == null) {
                    File(researchDefaultDirectory(), candidate).exists()
                } else {
                    findResearchDocument(treeUri, candidate) != null
                }
        if (!exists(name)) return name
        val base = name.substringBeforeLast('.')
        var suffix = 2
        var candidate = "$base ($suffix).pdf"
        while (exists(candidate)) candidate = "$base (${++suffix}).pdf"
        return candidate
    }

    private fun beginResearchPdf(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val name = try {
            safeResearchFilename(call.argument<String>("name"))
        } catch (_: Exception) {
            result.error("FILENAME", "PDF 文件名无效", null)
            return
        }
        researchPdfIo.execute {
            var temporaryFile: File? = null
            var temporaryUri: Uri? = null
            try {
                val treeUri = researchTreeUri()
                val finalName = availableResearchFilename(name, treeUri)
                val id = UUID.randomUUID().toString()
                val output: OutputStream
                if (treeUri == null) {
                    temporaryFile = File(researchDefaultDirectory(), ".research-$id.part")
                    output = temporaryFile!!.outputStream()
                } else {
                    val parentId = DocumentsContract.getTreeDocumentId(treeUri)
                    val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                    temporaryUri = DocumentsContract.createDocument(
                        contentResolver,
                        parentUri,
                        "application/octet-stream",
                        ".research-$id.part",
                    ) ?: error("无法在所选文件夹创建 PDF")
                    output = contentResolver.openOutputStream(temporaryUri!!, "w")
                        ?: error("无法写入所选文件夹")
                }
                researchPdfWriters[id] = ResearchPdfWriter(
                    finalName,
                    temporaryFile,
                    temporaryUri,
                    treeUri,
                    output,
                )
                runOnUiThread { result.success(mapOf("id" to id, "name" to finalName)) }
            } catch (_: Exception) {
                temporaryFile?.delete()
                temporaryUri?.let {
                    try { DocumentsContract.deleteDocument(contentResolver, it) } catch (_: Exception) {}
                }
                runOnUiThread {
                    result.error("SAVE", "无法创建 PDF，请检查剩余空间或文件夹权限", null)
                }
            }
        }
    }

    private fun writeResearchPdfChunk(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val bytes = call.argument<ByteArray>("bytes")
        val writer = id?.let(researchPdfWriters::get)
        if (writer == null || bytes == null) {
            result.error("DOWNLOAD", "PDF 下载状态已失效", null)
            return
        }
        researchPdfIo.execute {
            try {
                writer.output.write(bytes)
                writer.size += bytes.size
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                runOnUiThread { result.error("WRITE", "PDF 写入失败，请检查保存位置", null) }
            }
        }
    }

    private fun finishResearchPdf(id: String?, result: MethodChannel.Result) {
        val writer = id?.let(researchPdfWriters::remove)
        if (writer == null) {
            result.error("DOWNLOAD", "PDF 下载状态已失效", null)
            return
        }
        researchPdfIo.execute {
            try {
                writer.output.close()
                val savedUri = if (writer.temporaryFile != null) {
                    val target = File(researchDefaultDirectory(), writer.name)
                    check(!target.exists()) { "PDF 文件名已被占用" }
                    if (!writer.temporaryFile.renameTo(target)) {
                        check(target.createNewFile()) { "无法创建 PDF 文件" }
                        try {
                            writer.temporaryFile.inputStream().use { input ->
                                target.outputStream().use { output -> input.copyTo(output) }
                            }
                        } catch (error: Exception) {
                            target.delete()
                            throw error
                        }
                        writer.temporaryFile.delete()
                    }
                    FileProvider.getUriForFile(this, "$packageName.travel_exports", target)
                } else {
                    val temporaryUri = requireNotNull(writer.temporaryUri)
                    val renamed = try {
                        DocumentsContract.renameDocument(contentResolver, temporaryUri, writer.name)
                    } catch (_: Exception) {
                        null
                    }
                    renamed ?: run {
                        val treeUri = requireNotNull(writer.treeUri)
                        val parentId = DocumentsContract.getTreeDocumentId(treeUri)
                        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                        val target = DocumentsContract.createDocument(
                            contentResolver, parentUri, "application/pdf", writer.name
                        ) ?: error("无法完成 PDF 文件保存")
                        try {
                            val input = contentResolver.openInputStream(temporaryUri)
                                ?: error("无法读取临时 PDF")
                            val output = contentResolver.openOutputStream(target, "w")
                                ?: error("无法写入所选文件夹")
                            input.use { source ->
                                output.use { destination -> source.copyTo(destination) }
                            }
                        } catch (error: Exception) {
                            try { DocumentsContract.deleteDocument(contentResolver, target) } catch (_: Exception) {}
                            throw error
                        }
                        DocumentsContract.deleteDocument(contentResolver, temporaryUri)
                        target
                    }
                }
                val item = mapOf(
                        "name" to writer.name,
                        "uri" to savedUri.toString(),
                        "size" to writer.size,
                        "modifiedAt" to System.currentTimeMillis(),
                    )
                runOnUiThread { result.success(item) }
            } catch (_: Exception) {
                cleanupResearchPdf(writer)
                runOnUiThread { result.error("SAVE", "无法完成 PDF 保存，请重试", null) }
            }
        }
    }

    private fun abortResearchPdf(id: String?, result: MethodChannel.Result) {
        val writer = id?.let(researchPdfWriters::remove)
        if (writer == null) {
            result.success(null)
            return
        }
        researchPdfIo.execute {
            cleanupResearchPdf(writer)
            runOnUiThread { result.success(null) }
        }
    }

    private fun cleanupResearchPdf(writer: ResearchPdfWriter) {
        try { writer.output.close() } catch (_: Exception) {}
        writer.temporaryFile?.delete()
        writer.temporaryUri?.let {
            try { DocumentsContract.deleteDocument(contentResolver, it) } catch (_: Exception) {}
        }
    }

    private fun listResearchPapers(result: MethodChannel.Result) {
        researchPdfIo.execute {
            try {
                val items = mutableListOf<Map<String, Any>>()
                val treeUri = researchTreeUri()
                if (treeUri == null) {
                    researchDefaultDirectory().listFiles()?.filter {
                        it.isFile && it.extension.equals("pdf", ignoreCase = true)
                    }?.forEach { file ->
                        items.add(mapOf(
                            "name" to file.name,
                            "uri" to FileProvider.getUriForFile(
                                this, "$packageName.travel_exports", file
                            ).toString(),
                            "size" to file.length(),
                            "modifiedAt" to file.lastModified(),
                        ))
                    }
                } else {
                    val treeId = DocumentsContract.getTreeDocumentId(treeUri)
                    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeId)
                    contentResolver.query(
                        childrenUri,
                        arrayOf(
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                            DocumentsContract.Document.COLUMN_MIME_TYPE,
                            DocumentsContract.Document.COLUMN_SIZE,
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                        ),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                        val nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                        val mimeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                        val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                        val modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                        while (cursor.moveToNext()) {
                            val name = if (nameColumn >= 0) cursor.getString(nameColumn) ?: "论文.pdf" else "论文.pdf"
                            val mime = if (mimeColumn >= 0) cursor.getString(mimeColumn) else null
                            if (!name.endsWith(".pdf", ignoreCase = true) && mime != "application/pdf") continue
                            if (idColumn < 0) continue
                            val uri = DocumentsContract.buildDocumentUriUsingTree(
                                treeUri, cursor.getString(idColumn)
                            )
                            items.add(mapOf(
                                "name" to name,
                                "uri" to uri.toString(),
                                "size" to if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else 0L,
                                "modifiedAt" to if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) cursor.getLong(modifiedColumn) else 0L,
                            ))
                        }
                    }
                }
                runOnUiThread { result.success(items.sortedByDescending { it["modifiedAt"] as Long }) }
            } catch (_: Exception) {
                runOnUiThread { result.error("LIST", "无法读取所选论文文件夹", null) }
            }
        }
    }

    private fun openResearchPdf(value: String?, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(requireNotNull(value))
            require(uri.scheme == "content")
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/pdf")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(contentResolver, "论文 PDF", uri)
            }
            startActivity(Intent.createChooser(intent, "打开论文 PDF"))
            result.success(null)
        } catch (_: android.content.ActivityNotFoundException) {
            result.error("VIEWER", "设备上没有可打开 PDF 的应用", null)
        } catch (_: Exception) {
            result.error("VIEWER", "无法打开该 PDF", null)
        }
    }

    private fun pickSkillAgentDocument(result: MethodChannel.Result) {
        if (pendingSkillAgentFileResult != null) {
            result.error("PICKER_BUSY", "已有文件选择窗口打开", null)
            return
        }
        try {
            pendingSkillAgentFileResult = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                    "text/markdown", "text/plain", "application/pdf", "application/octet-stream"
                ))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(intent, skillAgentFileRequest)
        } catch (_: Exception) {
            pendingSkillAgentFileResult = null
            result.error("PICKER", "无法打开系统文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == researchDirectoryRequest) {
            val result = pendingResearchDirectoryResult ?: return
            pendingResearchDirectoryResult = null
            val uri = data?.data
            if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
                result.success(null)
                return
            }
            try {
                val flags = data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                contentResolver.takePersistableUriPermission(uri, flags)
                getSharedPreferences("research_papers", MODE_PRIVATE).edit()
                    .putString("treeUri", uri.toString()).apply()
                result.success(researchDirectoryInfo())
            } catch (_: Exception) {
                result.error("DIRECTORY", "无法保存该文件夹的访问权限，请重新选择", null)
            }
            return
        }
        if (requestCode != skillAgentFileRequest) return
        val result = pendingSkillAgentFileResult ?: return
        pendingSkillAgentFileResult = null
        val uri = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        Thread {
            try {
                val filename = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
                } ?: "资料文件"
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    var count = input.read(buffer)
                    while (count != -1) {
                        if (output.size() + count > skillAgentMaxFileBytes) {
                            throw IllegalArgumentException("文件不能超过 10 MB")
                        }
                        output.write(buffer, 0, count)
                        count = input.read(buffer)
                    }
                    output.toByteArray()
                } ?: throw IllegalArgumentException("无法读取所选文件")
                runOnUiThread { result.success(mapOf("name" to filename, "bytes" to bytes)) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("PICKER", error.message ?: "无法读取所选文件", null)
                }
            }
        }.start()
    }

    private fun shareTravelFiles(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            val files = call.argument<List<*>>("files").orEmpty()
            require(files.isNotEmpty())
            val subject = call.argument<String>("subject") ?: "旅游计划"
            val directory = File(cacheDir, "travel_exports").apply { mkdirs() }
            val staleBefore = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
            directory.listFiles()?.filter { it.lastModified() < staleBefore }?.forEach { it.delete() }

            val uris = ArrayList<Uri>()
            val mimeTypes = mutableSetOf<String>()
            for (entry in files) {
                val item = entry as? Map<*, *> ?: error("Invalid export item")
                val name = (item["name"] as? String ?: "travel-export.bin")
                    .replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
                    .take(100)
                val bytes = item["bytes"] as? ByteArray ?: error("Invalid export bytes")
                val mimeType = item["mimeType"] as? String ?: "application/octet-stream"
                val file = File(directory, "${System.nanoTime()}_$name")
                file.writeBytes(bytes)
                mimeTypes.add(mimeType)
                uris.add(FileProvider.getUriForFile(this, "$packageName.travel_exports", file))
            }

            val multiple = uris.size > 1
            val intent = Intent(if (multiple) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
                type = if (multiple && mimeTypes.all { it.startsWith("image/") }) "image/*"
                    else if (multiple) "*/*" else mimeTypes.first()
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(contentResolver, subject, uris.first()).apply {
                    uris.drop(1).forEach { addItem(ClipData.Item(it)) }
                }
                if (multiple) putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                else putExtra(Intent.EXTRA_STREAM, uris.first())
            }
            startActivity(Intent.createChooser(intent, subject))
            result.success(null)
        } catch (_: Exception) {
            result.error("EXPORT", "无法打开系统分享面板，请重试", null)
        }
    }

    private fun hasNotificationPermission(): Boolean {
        val permissionGranted = Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val notificationsEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .areNotificationsEnabled()
        return permissionGranted && notificationsEnabled
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(hasNotificationPermission())
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("PERMISSION_PENDING", "通知权限请求正在处理中", null)
            return
        }
        pendingNotificationPermission = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest) {
            pendingNotificationPermission?.success(
                grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED &&
                    hasNotificationPermission()
            )
            pendingNotificationPermission = null
        }
    }

    private fun canScheduleExactAlarms() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()

    private fun openNotificationSettings(result: MethodChannel.Result) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, PomodoroAlert.CHANNEL)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            }
            startActivity(intent)
            result.success(null)
        } catch (_: Exception) {
            result.error("SETTINGS", "无法打开通知设置", null)
        }
    }

    private fun openExactAlarmSettings(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !canScheduleExactAlarms()) {
                startActivity(Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:$packageName")
                ))
            }
            result.success(null)
        } catch (_: Exception) {
            result.error("SETTINGS", "无法打开闹钟和提醒设置", null)
        }
    }

    private fun schedulePomodoroReminder(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        val triggerAt = call.argument<Number>("triggerAtMillis")?.toLong()
        val phase = call.argument<String>("phase")
        if (triggerAt == null || phase !in setOf("focus", "shortBreak", "longBreak")) {
            result.error("INVALID_REMINDER", "番茄钟提醒参数无效", null)
            return
        }
        if (!canScheduleExactAlarms()) {
            result.error("EXACT_ALARM_PERMISSION", "需要允许闹钟和提醒权限", null)
            return
        }
        try {
            cancelPomodoroReminder()
            val intent = Intent(this, PomodoroAlarmReceiver::class.java)
                .setAction(PomodoroAlert.ACTION)
                .putExtra("phase", phase)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val pending = PendingIntent.getBroadcast(this, PomodoroAlert.REQUEST_CODE, intent, flags)
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
            result.success(null)
        } catch (_: SecurityException) {
            result.error("EXACT_ALARM_PERMISSION", "需要允许闹钟和提醒权限", null)
        } catch (_: Exception) {
            result.error("SCHEDULE_FAILED", "无法设置番茄钟后台提醒", null)
        }
    }

    private fun cancelPomodoroReminder() {
        val intent = Intent(this, PomodoroAlarmReceiver::class.java).setAction(PomodoroAlert.ACTION)
        val flags = PendingIntent.FLAG_NO_CREATE or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        PendingIntent.getBroadcast(this, PomodoroAlert.REQUEST_CODE, intent, flags)?.let {
            (getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(it)
            it.cancel()
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(PomodoroAlert.NOTIFICATION_ID)
    }

    private fun canInstall() = Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()

    @Suppress("DEPRECATION")
    private fun versionCode(info: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun install(file: File, expected: Long) {
        require(file.canonicalFile.parentFile == cacheDir.canonicalFile && file.isFile)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val incoming = requireNotNull(packageManager.getPackageArchiveInfo(file.path, flags))
        val current = packageManager.getPackageInfo(packageName, flags)
        require(incoming.packageName == packageName && versionCode(incoming) == expected && expected > versionCode(current))
        val incomingSigners = if (Build.VERSION.SDK_INT >= 28) incoming.signingInfo?.apkContentsSigners else incoming.signatures
        val currentSigners = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
        require(!incomingSigners.isNullOrEmpty() && !currentSigners.isNullOrEmpty() &&
            incomingSigners.toSet() == currentSigners.toSet())

        val installer = packageManager.packageInstaller
        val prefs = getSharedPreferences("updates", MODE_PRIVATE)
        prefs.edit().putInt("activeSession", -1).apply()
        installer.mySessions.filter { it.appPackageName == packageName }.forEach {
            try { installer.abandonSession(it.sessionId) } catch (_: Exception) { }
        }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        params.setSize(file.length())
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        prefs.edit().putInt("activeSession", id).apply()
        try {
            installer.openSession(id).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val callback = Intent(this, UpdateInstallReceiver::class.java).setAction("$packageName.UPDATE_RESULT")
                val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val pending = PendingIntent.getBroadcast(this, id, callback, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(id)
            throw error
        }
    }
}
