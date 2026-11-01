package app.todotim.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.todotim.android.data.LoadState
import app.todotim.android.ui.TodoTimApp
import app.todotim.android.ui.theme.TodoTimTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()
    private val graph get() = (application as TodoTimApplication).graph

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            TodoTimTheme {
                val state by graph.state.collectAsState()
                when (val s = state) {
                    is LoadState.Ready -> TodoTimApp(vm, s.loaded.store, s.loaded.sync, graph.settings)
                    is LoadState.Failed -> Box(
                        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) { Text(s.message, color = MaterialTheme.colorScheme.error) }
                    // Loading takes a few milliseconds: an empty surface, no spinner flash.
                    LoadState.Loading -> Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface))
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // App start (once loaded) and every return to the foreground, at most once a minute.
        graph.scope.launch { runCatching { graph.await() }.getOrNull()?.sync?.syncIfStale() }
    }

    override fun onStop() {
        super.onStop()
        graph.flush()
    }
}
