import std.file;
import std.path;
import convertscene;

void main(string[] args)
{
	string inputDir = absolutePath(args.length > 1 ? args[1] : "importScenes/");
	string outputDir = args.length > 2 ? args[2] : "exportScenes/";

	foreach(sceneFile; dirEntries(inputDir, SpanMode.breadth))
	{
		auto inputPath = relativePath(sceneFile.name);
		convertScene(inputPath, relativePath(sceneFile.name, inputDir), outputDir);
	}
}