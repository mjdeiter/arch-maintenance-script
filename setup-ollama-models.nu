#!/usr/bin/env nu
# === Clean Ollama Model Setup Script ===
# Compatible with Nushell 0.106.1+

def create-model [
    name: string,
    base: string,
    --ctx: int,  # Optional context length
    --temp: float,  # Optional temperature setting
    --top-p: float  # Optional top-p setting
] {
    # Validate inputs
    if ($name | str trim | is-empty) {
        print "❌ Error: Model name cannot be empty"
        return
    }

    if ($base | str trim | is-empty) {
        print "❌ Error: Base model cannot be empty"
        return
    }

    # Build Modelfile content
    mut content = $"FROM ($base)"

    if ($ctx | describe) != "nothing" {
        $content = $content + $"\nPARAMETER num_ctx ($ctx)"
    }

    if ($temp | describe) != "nothing" {
        $content = $content + $"\nPARAMETER temperature ($temp)"
    }

    if ($top_p | describe) != "nothing" {
        $content = $content + $"\nPARAMETER top_p ($top_p)"
    }

    # Write Modelfile
    $content | save Modelfile -f

    # Get existing models - simplified approach
    let existing_models = try {
        ollama list
        | lines
        | skip 1
        | each { |line|
            if ($line | str trim | is-empty) or ($line | str contains "NAME") {
                ""
            } else {
                $line | str trim | split row -r '\s+' | first | str replace ":latest" ""
            }
        }
        | where $it != ""
    } catch {
        []
    }

    # Check if model exists (without :latest suffix)
    let model_name = $name | str replace ":latest" ""
    if $model_name in $existing_models {
        print $"💡 Model '($name)' already exists. Skipping creation."
        return
    }

    # Create the model
    print $"🚀 Creating model '($name)'..."
    let result = ollama create $name -f Modelfile | complete

    if $result.exit_code == 0 {
        # Build parameter display
        let params = [
            (if ($ctx | describe) != "nothing" { $"ctx: ($ctx)" } else { null }),
            (if ($temp | describe) != "nothing" { $"temp: ($temp)" } else { null }),
            (if ($top_p | describe) != "nothing" { $"top_p: ($top_p)" } else { null })
        ] | compact | str join ", "

        let param_display = if ($params | is-empty) { "default" } else { $params }
        print $"✅ Created '($name)' successfully - base: ($base), params: ($param_display)"
    } else {
        print $"❌ Failed to create model '($name)'"
        if ($result.stderr | str trim | is-not-empty) {
            print $"   Error: ($result.stderr)"
        }
    }
}

# Helper function to check Ollama
def check-ollama [] {
    let result = ollama list | complete
    if $result.exit_code == 0 {
        print "✅ Ollama is running and accessible"
        true
    } else {
        print "❌ Ollama not accessible. Please ensure Ollama is installed and running."
        false
    }
}

# Pre-flight check
if not (check-ollama) {
    exit 1
}

print "🎯 Setting up Qwen model variants..."
print ""

# === Create Models ===
create-model qwen-fast  qwen:14b
create-model qwen-pro   qwen:32b --ctx 16384
create-model qwen-mega  qwen:72b --ctx 8192
create-model qwen-long  qwen:14b --ctx 32768
create-model qwen-lite  qwen:latest --ctx 4096
create-model qwen-creative qwen:14b --temp 0.8 --top-p 0.9
create-model qwen-precise  qwen:32b --temp 0.1 --ctx 16384

# Cleanup
try { rm Modelfile } catch { }

print ""
print "✨ Ollama model setup complete!"
print ""
print "📋 Available models:"
ollama list
