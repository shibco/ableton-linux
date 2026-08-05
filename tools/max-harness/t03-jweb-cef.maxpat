{
	"patcher" : 	{
		"fileversion" : 1,
		"appversion" : 		{
			"major" : 9,
			"minor" : 1,
			"revision" : 4,
			"architecture" : "x64",
			"modernui" : 1
		},
		"classnamespace" : "box",
		"rect" : [ 140.0, 140.0, 900.0, 700.0 ],
		"boxes" : [ 			{
				"box" : 				{
					"id" : "obj-1",
					"maxclass" : "newobj",
					"text" : "loadbang",
					"numinlets" : 0,
					"numoutlets" : 1,
					"outlettype" : [ "bang" ],
					"patching_rect" : [ 30.0, 30.0, 60.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-2",
					"maxclass" : "message",
					"text" : "HARNESS t03 jweb loaded",
					"numinlets" : 2,
					"numoutlets" : 1,
					"outlettype" : [ "" ],
					"patching_rect" : [ 130.0, 30.0, 160.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-3",
					"maxclass" : "newobj",
					"text" : "print HARNESS",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 310.0, 30.0, 90.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-4",
					"maxclass" : "jweb",
					"url" : "https://example.com",
					"numinlets" : 1,
					"numoutlets" : 2,
					"outlettype" : [ "", "" ],
					"patching_rect" : [ 30.0, 80.0, 820.0, 560.0 ]
				}
			}
 ],
		"lines" : [ 			{
				"patchline" : 				{
					"source" : [ "obj-1", 0 ],
					"destination" : [ "obj-2", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-2", 0 ],
					"destination" : [ "obj-3", 0 ]
				}
			}
 ]
	}
}
