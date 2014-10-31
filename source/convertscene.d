module convertscene;

import std.exception;
import derelict.assimp3.assimp;
import std.string;
import kratos.graphics.shadervariable;
import kratos.graphics.bo;
import std.algorithm;
import std.array;
import vibe.data.json;
import std.typecons;
import kratos;
import std.path;
import std.conv : text;
import kratos.graphics.mesh;
import kratos.graphics.renderstate;
import std.file;
import std.stdio : File;
import std.stdio : writeln;

struct ImportedMesh
{
	VertexAttributes attributes;
	IndexType indexType;
	float[] vertexStream;
	void[] indexStream;
}

void convertScene(string inputPath, string outputBaseName, string outputBasePath)
{
	writeln("Input Path: ", inputPath);
	writeln("Output Base Path: ", outputBasePath);

	auto importedScene = aiImportFile(
		inputPath.toStringz(),
		aiProcess_CalcTangentSpace		|
		aiProcess_JoinIdenticalVertices	|
		aiProcess_Triangulate			|
		aiProcess_GenSmoothNormals		|
		aiProcess_ImproveCacheLocality	|
		aiProcess_FindInvalidData		|
		aiProcess_GenUVCoords			|
		aiProcess_FindInstances
	);

	enforce(importedScene, "Error while loading scene");
	scope(exit) aiReleaseImport(importedScene);

	auto importedMeshes = importedScene.mMeshes[0 .. importedScene.mNumMeshes].map!(a => importMesh(a)).array;
	auto importedMaterials = importedScene.mMaterials[0 .. importedScene.mNumMaterials].map!(a => importMaterial(a)).array;

	string[ImportedMesh] savedMeshes;
	string[Json] savedMaterials;
	bool[string] takenNames;

	auto scenePath = outputBaseName.stripExtension;
	writeln("Scene Path: ", scenePath);
	//TODO: Set Scene name
	auto scopedScene = scoped!Scene(scenePath.baseName);

	string saveMesh(ImportedMesh mesh, string baseName)
	{
		auto meshPath = buildNormalizedPath("Meshes", baseName ~ ".ksm").relativePath(outputBasePath).replace("\\", "/");
		for(int i = 0; meshPath in takenNames; ++i)
		{
			meshPath = buildNormalizedPath("Meshes", baseName ~ "_" ~ i.text ~ ".ksm").relativePath(outputBasePath).replace("\\", "/");
		}
		takenNames[meshPath] = true;
		savedMeshes[mesh] = meshPath;
		writeln("Mesh Path: ", meshPath);

		auto fullPath = buildNormalizedPath(outputBasePath, meshPath);
		mkdirRecurse(fullPath.dirName);
		auto outFile = File(fullPath, "w");
		outFile.rawWrite([mesh.attributes]);
		outFile.rawWrite([mesh.vertexStream.length]);
		outFile.rawWrite([mesh.indexType]);
		outFile.rawWrite([mesh.indexStream.length]);
		outFile.rawWrite(mesh.vertexStream);
		outFile.rawWrite(mesh.indexStream);

		return meshPath;
	}

	string saveMaterial(Json material, string baseName)
	{
		auto materialPath = buildNormalizedPath("RenderStates", baseName ~ ".renderstate").replace("\\", "/");
		for(int i = 0; materialPath in takenNames; ++i)
		{
			materialPath = buildNormalizedPath("RenderStates", baseName ~ "_" ~ i.text ~ ".renderstate").replace("\\", "/");
		}
		takenNames[materialPath] = true;
		savedMaterials[material] = materialPath;
		writeln("Material Path: ", materialPath);

		auto fullPath = buildNormalizedPath(outputBasePath, materialPath);
		mkdirRecurse(fullPath.dirName);
		write(fullPath, material.toPrettyString);
		
		return materialPath;
	}

	void loadNode(const aiNode* node, Transform parent)
	{
		auto entity = scopedScene.createEntity(node.mName.data[0 .. node.mName.length].idup);
		auto transform = entity.addComponent!Transform;
		transform.parent = parent;
		transform.setLocalMatrix(*(cast(mat4*)&node.mTransformation));
		
		foreach(meshIndex; 0..node.mNumMeshes)
		{
			string meshPath;
			string materialPath;

			auto importedMeshIndex = node.mMeshes[meshIndex];
			auto importedMaterialIndex = importedScene.mMeshes[node.mMeshes[meshIndex]].mMaterialIndex;

			auto baseSaveName = buildNormalizedPath(scenePath, transform.path).replace("\\", "/");
			if(auto pathPtr = importedMeshes[importedMeshIndex] in savedMeshes)
			{
				meshPath = *pathPtr;
			}
			else
			{
				meshPath = saveMesh(importedMeshes[importedMeshIndex], baseSaveName);
			}

			if(auto pathPtr = importedMaterials[importedMaterialIndex] in savedMaterials)
			{
				materialPath = *pathPtr;
			}
			else
			{
				materialPath = saveMaterial(importedMaterials[importedMaterialIndex], baseSaveName);
			}

			Mesh mesh;
			mesh.id = meshPath;
			RenderState renderState;
			renderState.id = materialPath;

			auto meshRenderer = entity.addComponent!MeshRenderer(mesh, renderState);
		}
		
		foreach(childIndex; 0..node.mNumChildren)
		{
			loadNode(node.mChildren[childIndex], transform);
		}
	}
	
	loadNode(importedScene.mRootNode, null);

	auto outputScenePath = buildPath(outputBasePath, "Scenes", scenePath ~ ".scene");
	mkdirRecurse(outputScenePath.dirName);
	write(outputScenePath, scopedScene.Scoped_payload.serializeToJson.toPrettyString);
}

ImportedMesh importMesh(const aiMesh* mesh)
{
	VertexAttributes attributes;
	
	attributes.add(VertexAttribute.fromAggregateType!vec3("position"));
	if(mesh.mNormals)		attributes.add(VertexAttribute.fromAggregateType!vec3("normal"));
	if(mesh.mTangents)		attributes.add(VertexAttribute.fromAggregateType!vec3("tangent"));
	if(mesh.mBitangents)	attributes.add(VertexAttribute.fromAggregateType!vec3("bitangent"));
	foreach(i, texCoordChannel; mesh.mTextureCoords)
	{
		if(texCoordChannel)	attributes.add(VertexAttribute.fromBasicType!float(mesh.mNumUVComponents[i], "texCoord" ~ i.text));
	}
	
	float[] buffer;
	assert(attributes.totalByteSize % float.sizeof == 0);
	buffer.reserve(attributes.totalByteSize / float.sizeof * mesh.mNumVertices);
	
	foreach(vertexIndex; 0..mesh.mNumVertices)
	{
		static void appendVector(ref float[] buffer, aiVector3D vector, size_t numElements = 3)
		{
			auto vectorSlice = (&vector.x)[0..numElements];
			buffer ~= vectorSlice;
		}
		
		appendVector(buffer, mesh.mVertices[vertexIndex]);
		if(mesh.mNormals)		appendVector(buffer, mesh.mNormals[vertexIndex]);
		if(mesh.mTangents)		appendVector(buffer, mesh.mTangents[vertexIndex]);
		if(mesh.mBitangents)	appendVector(buffer, mesh.mBitangents[vertexIndex]);
		foreach(channelIndex, texCoordChannel; mesh.mTextureCoords)
		{
			if(texCoordChannel)	appendVector(buffer, texCoordChannel[vertexIndex], mesh.mNumUVComponents[channelIndex]);
		}
	}

	T[] createIndices(T)()
	{
		T[] indices;
		indices.reserve(mesh.mNumFaces * 3);
		foreach(i; 0..mesh.mNumFaces)
		{
			auto face = mesh.mFaces[i];
			assert(face.mNumIndices == 3);
			foreach(index; face.mIndices[0 .. face.mNumIndices])
			{
				import std.conv;
				indices ~= index.to!T;
			}
		}
		
		return indices;
	}

	ImportedMesh importedMesh;
	importedMesh.attributes = attributes;
	importedMesh.vertexStream = buffer;

	if(mesh.mNumVertices < ushort.max)
	{
		importedMesh.indexType = IndexType.UShort;
		importedMesh.indexStream = createIndices!ushort;
	}
	else
	{
		importedMesh.indexType = IndexType.UInt;
		importedMesh.indexStream = createIndices!uint;
	}

	return importedMesh;
}

Json importMaterial(const aiMaterial* material)
{
	auto json = Json.emptyObject;
	json["parent"] = "RenderStates/DefaultImport.renderstate";
	auto uniforms = json["uniforms"] = Json.emptyObject;

	static struct TextureProperties
	{
		string uniformName;
		aiTextureType textureType;
		string defaultTexture = "Textures/White.png";
	}
	
	foreach(properties; [
		TextureProperties("diffuseTexture", aiTextureType_DIFFUSE),
		TextureProperties("specularTexture", aiTextureType_SPECULAR),
		TextureProperties("emissiveTexture", aiTextureType_EMISSIVE, "Textures/Black.png")
	])
	{
		aiString path;
		if(aiGetMaterialTexture(material, properties.textureType, 0, &path) == aiReturn_SUCCESS)
		{
			uniforms[properties.uniformName] = path.data[0..path.length].idup;
		}
	}
	
	auto ambientColor = vec4(1, 1, 1, 1);
	aiGetMaterialColor(material, AI_MATKEY_COLOR_AMBIENT, 0, 0, cast(aiColor4D*)&ambientColor);
	auto diffuseColor = vec4(1, 1, 1, 1);
	aiGetMaterialColor(material, AI_MATKEY_COLOR_DIFFUSE, 0, 0, cast(aiColor4D*)&diffuseColor);
	auto specularColor = vec4(1, 1, 1, 1);
	aiGetMaterialColor(material, AI_MATKEY_COLOR_SPECULAR, 0, 0, cast(aiColor4D*)&specularColor);
	auto emissiveColor = vec4(0, 0, 0, 0);
	aiGetMaterialColor(material, AI_MATKEY_COLOR_EMISSIVE, 0, 0, cast(aiColor4D*)&emissiveColor);
	
	uniforms["ambientColor"] = serializeToJson(ambientColor.rgb);
	uniforms["diffuseColor"] = serializeToJson(diffuseColor);
	uniforms["specularColor"] = serializeToJson(specularColor);
	uniforms["emissiveColor"] = serializeToJson(emissiveColor.rgb);

	return json;
}

shared static this()
{
	DerelictASSIMP3.load();
}

shared static ~this()
{
	DerelictASSIMP3.unload();
}