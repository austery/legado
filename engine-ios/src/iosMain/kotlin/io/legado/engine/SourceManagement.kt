package io.legado.engine

import io.legado.app.constant.AppPattern

import io.legado.app.data.AppDbProviders
import io.legado.app.data.entities.BookSource
import io.legado.app.help.source.SourceHelp
import io.legado.app.utils.KS_JSON
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import platform.Foundation.NSUUID

enum class SourceImportKind { NEW, NEWER, EXISTING }
class ManagedSource internal constructor(val id: String, val name: String, val enabled: Boolean,
    val groups: List<String>, val updatedAt: Long)
class ManagedSourcesReply internal constructor(val sources: List<ManagedSource>) : EngineReply()
class SourceImportItem internal constructor(val source: ManagedSource, val kind: SourceImportKind,
    val selectedByDefault: Boolean, val duplicateCount: Int, val previousUpdatedAt: Long?)
class SourceImportPreview internal constructor(val token: String, val items: List<SourceImportItem>) : EngineReply()
class SourceExportReply internal constructor(val json: String, val count: Int) : EngineReply()
class SourceImportCommitted internal constructor(val count: Int) : EngineReply()

/** Instances are session-owned; callers serialize database access through EngineHost.gate. */
internal class SourceManagement {
    private data class Plan(val incoming: List<BookSource>, val expected: Map<String, BookSource?>)
    private val plans = mutableMapOf<String, Plan>()
    private val dao get() = AppDbProviders.get().bookSourceDao

    suspend fun list(): ManagedSourcesReply = ManagedSourcesReply(
        dao.all().filter { it.bookSourceType == 0 }.map(::snapshot))

    suspend fun selected(ids: List<String>): List<BookSource> {
        require(ids.isNotEmpty()) { "Select at least one source" }
        return ids.distinct().map { id ->
            val source = dao.getBookSource(id) ?: throw IllegalArgumentException("Source not found: $id")
            require(source.bookSourceType == 0) { "Only text sources can be managed here" }
            source
        }
    }

    suspend fun enable(ids: List<String>, enabled: Boolean): ManagedSourcesReply {
        val selectedIds = selected(ids).map { it.bookSourceUrl }.toSet()
        dao.enable(enabled, dao.allPart().filter { it.bookSourceUrl in selectedIds })
        SourceHelp.evictAll()
        return list()
    }

    suspend fun group(ids: List<String>, value: String, add: Boolean): ManagedSourcesReply {
        val group = value.trim()
        require(group.isNotEmpty() && !AppPattern.splitGroupRegex.containsMatchIn(group) && '\n' !in group && '\r' !in group) {
            "Enter one nonempty group name without group separators or line breaks"
        }
        selected(ids)
        dao.changeMembership(ids.distinct(), group, add)
        return list()
    }

    suspend fun preview(json: String): SourceImportPreview {
        val element = try { KS_JSON.parseToJsonElement(json) }
            catch (error: SerializationException) { throw IllegalArgumentException("Malformed source JSON", error) }
        val incoming = try { when (element) {
            is JsonArray -> KS_JSON.decodeFromJsonElement(ListSerializer(BookSource.serializer()), element)
            is JsonObject -> listOf(KS_JSON.decodeFromJsonElement(BookSource.serializer(), element))
            else -> throw IllegalArgumentException("Expected a source object or array")
        } } catch (error: SerializationException) { throw IllegalArgumentException("Invalid source schema", error) }
        require(incoming.isNotEmpty()) { "No sources supplied" }
        require(incoming.all { it.bookSourceUrl.isNotBlank() && it.bookSourceName.isNotBlank() && it.bookSourceType == 0 }) {
            "Every source needs an identity, name, and supported text type"
        }
        val unique = incoming.associateBy { it.bookSourceUrl }.values.toList()
        val expected = unique.associate { it.bookSourceUrl to dao.getBookSource(it.bookSourceUrl)?.copy() }
        val counts = incoming.groupingBy { it.bookSourceUrl }.eachCount()
        val token = NSUUID().UUIDString
        plans.clear()
        plans[token] = Plan(unique, expected)
        return SourceImportPreview(token, unique.map { source ->
            val old = expected[source.bookSourceUrl]
            val kind = if (old == null) SourceImportKind.NEW else if (source.lastUpdateTime > old.lastUpdateTime)
                SourceImportKind.NEWER else SourceImportKind.EXISTING
            SourceImportItem(snapshot(source), kind, kind != SourceImportKind.EXISTING,
                counts.getValue(source.bookSourceUrl) - 1, old?.lastUpdateTime)
        })
    }

    fun cancelPreview() { plans.clear() }

    suspend fun commit(token: String, ids: List<String>, keepName: Boolean, keepGroups: Boolean,
        keepEnabled: Boolean): SourceImportCommitted {
        val plan = plans[token] ?: throw io.legado.app.data.dao.SourceImportConflict()
        require(ids.isNotEmpty()) { "Select at least one source to import" }
        require(ids.all { it in plan.expected }) { "Selection is outside this preview" }
        val selection = ids.toSet()
        val replacements = plan.incoming.filter { it.bookSourceUrl in selection }.map { incoming ->
            incoming.copy().also { source ->
                plan.expected[source.bookSourceUrl]?.let { old ->
                    source.customOrder = old.customOrder
                    if (keepName) source.bookSourceName = old.bookSourceName
                    if (keepGroups) source.bookSourceGroup = old.bookSourceGroup
                    if (keepEnabled) {
                        source.enabled = old.enabled
                        source.enabledExplore = old.enabledExplore
                    }
                }
            }
        }
        dao.importReviewed(plan.expected.filterKeys { it in selection }, replacements)
        plans.clear()
        SourceHelp.evictAll()
        return SourceImportCommitted(replacements.size)
    }

    suspend fun export(ids: List<String>): SourceExportReply {
        val sources = selected(ids).map { it.copy(enableDangerousApi = false) }
        return SourceExportReply(KS_JSON.encodeToString(ListSerializer(BookSource.serializer()), sources), sources.size)
    }

    private fun snapshot(source: BookSource) = ManagedSource(source.bookSourceUrl, source.bookSourceName,
        source.enabled, source.bookSourceGroup.orEmpty().split(AppPattern.splitGroupRegex).map { it.trim() }
            .filter { it.isNotEmpty() }.distinct(), source.lastUpdateTime)
}
